# DVAI Hub Homebrew formula.
#
# Distribution: install via the project's tap once it's published:
#
#     brew tap deepvoiceai/dvai-hub https://github.com/dvai-global/homebrew-dvai-hub
#     brew install dvai-hub
#
# This file is the canonical source. The companion repo
# `dvai-global/homebrew-dvai-hub` receives an automated PR from the
# release workflow on every `v3.1.*` tag — the workflow updates the
# `version`, `url`, and `sha256` here and opens a PR to that repo's
# `Formula/dvai-hub.rb`.

class DvaiHub < Formula
  desc "Local-network LLM inference hub — pair mobile apps to a strong peer"
  homepage "https://github.com/dvai-global/dvai-bridge"
  version "3.1.0"
  license "Custom — see LICENSE"

  if Hardware::CPU.arm?
    url "https://github.com/dvai-global/dvai-bridge/releases/download/v#{version}/DVAI-Hub_#{version}_aarch64.dmg"
    sha256 "REPLACED_BY_RELEASE_WORKFLOW_AARCH64"
  else
    url "https://github.com/dvai-global/dvai-bridge/releases/download/v#{version}/DVAI-Hub_#{version}_x64.dmg"
    sha256 "REPLACED_BY_RELEASE_WORKFLOW_X86_64"
  end

  depends_on macos: :monterey

  def install
    # The .dmg has been mounted by Homebrew's `cask`-style install; the .app
    # is at the root of the mount. Move it under prefix.
    prefix.install "DVAI Hub.app"
    bin.write_exec_script "#{prefix}/DVAI Hub.app/Contents/MacOS/DVAI Hub"
  end

  test do
    # Smoke test — the app runs and reports its version.
    assert_match version.to_s, shell_output("#{bin}/dvai-hub --version")
  end
end
