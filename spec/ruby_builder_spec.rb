# frozen_string_literal: true

# Copyright (c) 2024-2025 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "tebako/ruby_builder"
require "tebako/build_helpers"
require "tebako/packager/patch_helpers"

# rubocop:disable Metrics/BlockLength

RSpec.describe Tebako::RubyBuilder do
  describe "#target_build" do
    let(:ruby_ver) { "3.3.11" }
    let(:src_dir) { "/path/to/src" }
    let(:ncores) { 4 }
    let(:builder) { described_class.new(Tebako::RubyVersion.new(ruby_ver), src_dir) }
    let(:output_type) { "package" }

    before do
      allow_any_instance_of(Tebako::ScenarioManagerBase).to receive(:ncores).and_return(ncores)
      allow(Tebako::BuildHelpers).to receive(:run_with_capture)
      allow(Dir).to receive(:chdir).with(src_dir).and_yield
      allow(builder).to receive(:native_link_current?).and_return(false)
      allow(builder).to receive(:record_native_link)
    end

    shared_examples "build behavior" do |type|
      it "prints the correct building message" do
        expect { builder.target_build(type) }.to output(/building tebako #{type}/).to_stdout
      end

      it "changes to the source directory" do
        expect(Dir).to receive(:chdir).with(src_dir).and_yield
        builder.target_build(type)
      end

      it "runs make with the correct number of cores" do
        expect(Tebako::BuildHelpers).to receive(:run_with_capture).with(["make", "-j#{ncores}"]).once
        builder.target_build(type)
      end
    end

    context "with 'package' output type" do
      include_examples "build behavior", "package"
    end

    context "with 'runtime package' output type" do
      include_examples "build behavior", "runtime package"
    end

    it "skips make when all native link inputs are unchanged" do
      allow(builder).to receive(:native_link_current?).and_return(true)
      expect(Tebako::BuildHelpers).not_to receive(:run_with_capture)
      expect { builder.target_build(output_type) }.to output(/reusing Ruby executable/).to_stdout
    end
  end

  describe "#target_link_with_application" do
    let(:src_dir) { "/path/to/src" }
    let(:builder) { described_class.new(Tebako::RubyVersion.new("3.3.11"), src_dir) }

    before do
      allow_any_instance_of(Tebako::ScenarioManagerBase).to receive(:ncores).and_return(4)
      allow(Dir).to receive(:chdir).with(src_dir).and_yield
      allow(FileUtils).to receive(:mkdir_p)
      allow(FileUtils).to receive(:rm_f)
      allow(FileUtils).to receive(:mv)
      allow(File).to receive(:file?).and_return(true)
      allow(SecureRandom).to receive(:hex).with(6).and_return("abcdef123456")
    end

    it "links a new executable with the application in a Mach-O section" do
      output = "/tmp/tebako-output"
      application = "/tmp/application envelope"
      flags = "-Xlinker -sectcreate -Xlinker __TEBAKO -Xlinker __app " \
              "-Xlinker \"#{File.expand_path(application)}\""
      expect(Tebako::BuildHelpers).to receive(:run_with_capture).with(
        [
          "make",
          "-f",
          "exts.mk",
          "tebako-bundle",
          "TEBAKO_BUNDLE_OUTPUT=.tebako-bundle-#{Process.pid}-abcdef123456",
          "TEBAKO_APPLICATION_LDFLAGS=#{flags}",
          "-j4"
        ]
      )
      expect(FileUtils).to receive(:mv).with(
        File.join(src_dir, ".tebako-bundle-#{Process.pid}-abcdef123456"),
        File.expand_path(output)
      )

      expect(builder.target_link_with_application(output, application)).to eq(output)
    end
  end

  describe "#toochain_build" do
    let(:ruby_ver) { "3.3.11" }
    let(:src_dir) { "/path/to/src" }
    let(:ncores) { 4 }
    let(:builder) { described_class.new(Tebako::RubyVersion.new(ruby_ver), src_dir) }

    before do
      allow_any_instance_of(Tebako::ScenarioManagerBase).to receive(:ncores).and_return(ncores)
      allow(Tebako::BuildHelpers).to receive(:run_with_capture)
      allow(Dir).to receive(:chdir).with(src_dir).and_yield
    end

    it "prints the building message" do
      expect { builder.toolchain_build }.to output(/building toolchain Ruby/).to_stdout
    end

    it "changes to the source directory" do
      expect(Dir).to receive(:chdir).with(src_dir).and_yield
      builder.toolchain_build
    end

    it "runs make with the correct number of cores" do
      expect(Tebako::BuildHelpers).to receive(:run_with_capture).with(["make", "-j#{ncores}"])
      expect(Tebako::BuildHelpers).to receive(:run_with_capture).with(["make", "install", "-j#{ncores}"])
      builder.toolchain_build
    end
  end
end
# rubocop:enable Metrics/BlockLength
