#ifndef EXLA_CLIENT_H_
#define EXLA_CLIENT_H_

#include <memory>
#include <utility>
#include <vector>

#include "exla_nif_util.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OwningOpRef.h"
#include "tsl/platform/status.h"
#include "tsl/platform/types.h"
#include "tsl/profiler/lib/profiler_factory.h"
#include "tsl/profiler/lib/profiler_interface.h"
#include "tsl/profiler/lib/profiler_session.h"
#include "tsl/profiler/lib/traceme.h"
#include "xla/pjrt/gpu/gpu_helpers.h"
#include "xla/pjrt/pjrt_client.h"

// The implementations in this module are designed after implementations
// in the XLA runtime, PjRt. Deviations are made where it makes sense
// to work better with the VM.

namespace exla {

class ExlaProfilerSession {
 public:
  ExlaProfilerSession();
  xla::StatusOr<std::string> Stop(std::string export_directory);

 private:
  std::unique_ptr<tsl::ProfilerSession> profiler_session_;
};

class ExlaClient;

class ExlaBuffer {
 public:
  ExlaBuffer(std::unique_ptr<xla::PjRtBuffer> buffer);

  int device_id() { return buffer_->device()->id(); }
  xla::PjRtBuffer* buffer() { return buffer_.get(); }
  xla::StatusOr<ExlaBuffer*> CopyToDevice(xla::PjRtDevice* dst_device);
  xla::StatusOr<ERL_NIF_TERM> ToBinary(ErlNifEnv* env, exla::int64 size);
  xla::Status Deallocate();

  xla::StatusOr<std::uintptr_t> GetDevicePointer(xla::PjRtClient* client) {
    return client->UnsafeBufferPointer(buffer_.get());
  }

  xla::StatusOr<size_t> GetOnDeviceSizeInBytes() {
    return buffer_.get()->GetOnDeviceSizeInBytes();
  }

  ~ExlaBuffer() {
    // Theoretically this may block if a computation is running
    // but we always block the host until the computation is done.
  }

 private:
  std::unique_ptr<xla::PjRtBuffer> buffer_;
};

class ExlaExecutable {
 public:
  ExlaExecutable(std::unique_ptr<xla::PjRtLoadedExecutable> executable,
                 absl::optional<std::string> fingerprint,
                 ExlaClient* client);

  xla::PjRtLoadedExecutable* executable() { return executable_.get(); }

  xla::StatusOr<ERL_NIF_TERM> Run(ErlNifEnv* env,
                                  ERL_NIF_TERM arguments,
                                  int device_id);

  xla::StatusOr<std::string> SerializeExecutable() { return executable_->SerializeExecutable(); }

 private:
  std::unique_ptr<xla::PjRtLoadedExecutable> executable_;
  absl::optional<std::string> fingerprint_;
  ExlaClient* client_;
};

class ExlaClient {
 public:
  explicit ExlaClient(std::shared_ptr<xla::PjRtClient> client);

  virtual ~ExlaClient() = default;

  xla::PjRtClient* client() { return client_.get(); }

  // Compiles the given computation with the given compile options

  xla::StatusOr<ExlaExecutable*> Compile(const mlir::OwningOpRef<mlir::ModuleOp>& computation,
                                         std::vector<xla::Shape> argument_layouts,
                                         xla::ExecutableBuildOptions& options,
                                         bool compile_portable_executable);

  xla::StatusOr<ExlaBuffer*> BufferFromBinary(ErlNifEnv* env,
                                              ERL_NIF_TERM binary_term,
                                              xla::Shape& shape,
                                              int device_id);

  xla::StatusOr<ExlaExecutable*> DeserializeExecutable(std::string serialized_executable);

  // TODO(seanmor5): This is device logic and should be refactored
  xla::Status TransferToInfeed(ErlNifEnv* env,
                               std::vector<ErlNifBinary> buffer_bins,
                               std::vector<xla::Shape> shapes,
                               int device_id);

  xla::StatusOr<ERL_NIF_TERM> TransferFromOutfeed(ErlNifEnv* env, int device_id, xla::Shape& shape);

 private:
  std::shared_ptr<xla::PjRtClient> client_;
};

xla::StatusOr<ExlaClient*> GetHostClient();

xla::StatusOr<ExlaClient*> GetGpuClient(double memory_fraction,
                                        bool preallocate,
                                        xla::GpuAllocatorConfig::Kind kind);

xla::StatusOr<ExlaClient*> GetTpuClient();

xla::StatusOr<ExlaClient*> GetCApiClient(std::string device_type);
}  // namespace exla

#endif
