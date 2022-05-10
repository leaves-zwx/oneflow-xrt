/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow_xrt/compiler/tensorrt/trt_executable.h"

#include <iostream>
#include <sstream>

#include "absl/strings/str_cat.h"
#include "cuda_runtime.h"
#include "oneflow_xrt/common/device.h"
#include "oneflow_xrt/compiler/tensorrt/trt_int8_calibrator.h"

namespace oneflow {
namespace xrt {

namespace tensorrt {

nvinfer1::ICudaEngine* TrtExecutable::CreateExecutableEngine(
    const ExecutableRunOptions& run_options, const int batch_size /*= 1*/,
    TRTInt8Calibrator* calibrator /*= nullptr*/) {
  CHECK(builder_ && network_) << "Builder and network should be setup before.";

  auto build_config =
      nv::unique_ptr<nvinfer1::IBuilderConfig>(builder_->createBuilderConfig());
  int64_t max_workspace_size = 1U << 24;  // 16MiB
  if (run_options.common.max_workspace_size() > 0) {
    max_workspace_size = run_options.common.max_workspace_size();
  }
  build_config->setMaxWorkspaceSize(max_workspace_size);

  nvinfer1::BuilderFlags flags = 0U;
  if (run_options.common.use_fp16()) {
    if (builder_->platformHasFastFp16()) {
      flags |= (1U << int(nvinfer1::BuilderFlag::kFP16));
    } else {
      LOG(INFO) << "TensorRT couldn't use fp16 precision since the GPU "
                   "hardware does not support.";
    }
  }
  if (run_options.common.use_int8()) {
    if (builder_->platformHasFastInt8()) {
      if (calibrator) {
        flags |= (1U << int(nvinfer1::BuilderFlag::kINT8));
        if (builder_->platformHasFastFp16()) {
          flags |= (1U << int(nvinfer1::BuilderFlag::kFP16));
        }
        build_config->setInt8Calibrator(calibrator);
      }
    } else {
      LOG(INFO) << "TensorRT couldn't use int8 precision since the GPU "
                   "hardware does not support.";
    }
  }
  // It does not guarantee to use low precision if just set kFP16 or kint8 flag,
  // but you can set kSTRICT_TYPES to enforce using half or int8 precision.
  // flags |= (1U << int(nvinfer1::BuilderFlag::kSTRICT_TYPES));

  // flags |= (1U << int(nvinfer1::BuilderFlag::kREFIT));
  build_config->setFlags(flags);

  int32_t max_batch_size = std::max(
      static_cast<int32_t>(run_options.common.max_batch_size()), batch_size);
  builder_->setMaxBatchSize(max_batch_size);
  // builder_->setGpuAllocator();
  return builder_->buildEngineWithConfig(*network_, *build_config);
}

bool TrtExecutable::ExecuteEngine(int batch_size, void** buffers, void* stream,
                                  bool block_until_done) {
  if (!execution_context_) {
    execution_context_.reset(engine_->createExecutionContext());
  }
  cudaStream_t cu_stream = reinterpret_cast<cudaStream_t>(stream);
  bool status = execution_context_->enqueueV2(buffers, cu_stream, nullptr);
  if (block_until_done) {
    CHECK_EQ(cudaSuccess, cudaStreamSynchronize(cu_stream));
  }
  return status;
}

std::string TrtExecutable::LoadCalibrationTable(
    const std::string& calibration_path) {
  std::string calib_restore_path(
      absl::StrCat(calibration_path, "/", this->name()));
  std::ifstream infile(calib_restore_path, std::ios::in);
  CHECK(infile.good()) << "Could not open calibration file: "
                       << calib_restore_path;
  std::stringstream buffer;
  buffer << infile.rdbuf();
  return buffer.str();
}

bool TrtExecutable::Run(const std::vector<Parameter>& inputs,
                        const ExecutableRunOptions& run_options,
                        bool block_until_done) {
  if (run_options.common.use_int8() && !calibrator_ &&
      run_options.common.int8_calibration().size()) {
    std::string calibration_data =
        LoadCalibrationTable(run_options.common.int8_calibration());
    CHECK(calibration_data.size()) << "Calibration data is empty";
    calibrator_.reset(new TRTInt8Calibrator(calibration_data));
  }
  if (!execution_context_ && !engine_) {
    engine_.reset(CreateExecutableEngine(run_options, 1 /*batch size*/,
                                         calibrator_.get()));
    CHECK(engine_) << "Cannot create TensorRT executable engine";
  }

  // all return params are the results of the executable
  this->results_ = run_options.return_params;

  const int num_bindings = engine_->getNbBindings();
  std::vector<const Parameter*> binding_params(num_bindings);
  std::vector<void*> buffers(num_bindings);
  for (const Parameter& input : inputs) {
    // returns -1 if the name is not found
    int index = engine_->getBindingIndex(input.name().data());
    if (index > -1) {
      binding_params[index] = &input;
      buffers[index] = input.data();
    }
  }
  for (const Parameter& output : this->results_) {
    // returns -1 if the name is not found
    int index = engine_->getBindingIndex(output.name().data());
    if (index > -1) {
      binding_params[index] = &output;
      buffers[index] = output.data();
    }
  }
  // TODO(hjchen2): check batch size is same for all binding parameters
  const int batch_size = binding_params[0]->shape().At(0);
  if (batch_size > engine_->getMaxBatchSize()) {
    LOG(WARNING) << "Rebuild engine since the maximum batch size "
                 << engine_->getMaxBatchSize()
                 << " is less than the input batch size " << batch_size;
    engine_.reset(
        CreateExecutableEngine(run_options, batch_size, calibrator_.get()));
    CHECK(engine_) << "Failed to create engine with batch size " << batch_size;
    execution_context_.reset(engine_->createExecutionContext());
  }

  if (run_options.common.use_int8() && !calibrator_) {
    auto* res = TRTInt8CalibratorResource::LookupOrCreate(this->name());
    {
      std::lock_guard<std::mutex> lock(res->mutex_);
      if (!res->calibrator_) {
        res->calibrator_.reset(new TRTInt8Calibrator());
        int ordinal = GetDeviceId(XrtDevice::GPU_CUDA);
        res->thread_.reset(
            new std::thread([this, ordinal, batch_size, res, run_options]() {
              SetDeviceId(XrtDevice::GPU_CUDA, ordinal);
              // TODO(hjchen2): TensorRT maybe crash if calibrator batch size >
              // 1
              res->calibrator_->setBatchSize(1 /*batch_size*/);
              res->engine_.reset(this->CreateExecutableEngine(
                  run_options, batch_size, res->calibrator_.get()));
            }));
      }
    }

    if (res->calibrator_->isDone()) {
      CHECK_EQ(cudaSuccess,
               cudaStreamSynchronize(
                   reinterpret_cast<cudaStream_t>(run_options.stream)));
      calibrator_ = res->calibrator_;
      execution_context_.reset(res->engine_->createExecutionContext());
    } else {
      res->calibrator_->setBatch(binding_params);
    }
  }

  return ExecuteEngine(batch_size, buffers.data(), run_options.stream,
                       block_until_done);
}

}  // namespace tensorrt

}  // namespace xrt
}  // namespace oneflow
