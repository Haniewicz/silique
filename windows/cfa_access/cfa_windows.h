#pragma once
#include "cfa_core.h"
#include <memory>

namespace cfa {
PathContext SystemPathContext();
Evidence QueryEvidence(const std::wstring& target, const std::optional<std::wstring>& root,
                       const PathContext& context);
// Read-only, fixed-local paths, final-handle identity, no reparse components.
bool ValidateReadOnlyPath(const std::wstring& path, bool directory, const PathContext& context);
// Validates only fixed, system-owned PowerShell/module files. Does not launch PowerShell.
bool ValidateSystemPowerShellReadOnly(const PathContext& context);

class NativePlatform final : public Platform {
 public:
  NativePlatform();
  ~NativePlatform() override;
  NativePlatform(const NativePlatform&) = delete;
  NativePlatform& operator=(const NativePlatform&) = delete;
  bool Elevated() override;
  bool Prepare(const std::optional<std::wstring>& root) override;
  bool ProtectedInstall() override;
  Evidence Confirm(const std::optional<std::wstring>& root) override;
  Status RequestElevation() override;
  bool AddAndVerify() override;
  std::wstring executable() const;
 private:
  struct State;
  std::unique_ptr<State> state_;
};
}
