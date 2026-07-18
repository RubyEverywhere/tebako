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

require "fileutils"
require "find"
require "digest"

require_relative "build_helpers"

# Tebako - an executable packager
module Tebako
  # Tebako packaging support (ruby builder)
  class RubyBuilder
    LINK_MANIFEST = ".tebako-link-manifest"

    def initialize(ruby_ver, src_dir)
      @ruby_ver = ruby_ver
      @src_dir = src_dir
      @ncores = ScenarioManagerBase.new.ncores
    end

    # Ruby's parallel build can race on ext/extinit.o: the `ruby` link step can start before
    # extinit.o is (re)built after configure-ext.mk is regenerated, giving
    # "clang: error: no such file or directory: 'ext/extinit.o'". A second, serial pass is
    # mostly cached and builds the raced target deterministically, so retry once serially.
    def make_target(*args)
      BuildHelpers.run_with_capture(["make", *args, "-j#{@ncores}"])
    rescue Tebako::Error
      BuildHelpers.run_with_capture(["make", *args])
    end

    # Final build of tebako package
    def toolchain_build
      puts "   ... building toolchain Ruby"
      Dir.chdir(@src_dir) do
        make_target
        make_target("install")
      end
    end

    # Final build of tebako package
    def target_build(output_type)
      puts "   ... building tebako #{output_type}"
      Dir.chdir(@src_dir) do
        if native_link_current?
          puts "   ... native link inputs are unchanged; reusing Ruby executable"
          next
        end

        make_target
        record_native_link
      end
    end

    private

    def native_link_current?
      executable = File.join(@src_dir, "ruby#{ScenarioManagerBase.new.exe_suffix}")
      return false unless File.file?(executable)

      manifest = File.join(@src_dir, LINK_MANIFEST)
      File.file?(manifest) && File.binread(manifest) == native_link_key
    end

    def native_link_key
      inputs = native_link_inputs.sort.map { |path| native_link_input(path) }
      Digest::SHA256.hexdigest(inputs.join("\0"))
    end

    def native_link_input(path)
      stat = File.stat(path)
      [path, stat.size, stat.mtime.to_r].join("\0")
    end

    def record_native_link
      File.write(File.join(@src_dir, LINK_MANIFEST), native_link_key)
    end

    def native_link_inputs
      inputs = native_link_patterns.flat_map { |pattern| Dir.glob(pattern) }
      inputs.concat(linked_archives)
      inputs.select { |path| File.file?(path) }.uniq
    end

    def native_link_patterns
      [
        File.join(@src_dir, "main.o"),
        File.join(@src_dir, "libruby*.a"),
        File.join(@src_dir, "ext", "**", "*.a"),
        File.join(@src_dir, "enc", "*.{a,o}"),
        File.join(@src_dir, "Makefile"),
        File.join(@src_dir, "exts.mk")
      ]
    end

    def linked_archives
      makefile = File.binread(File.join(@src_dir, "Makefile"))
      search_paths = makefile.scan(/-L(?:("[^"]+")|('[^']+')|(\S+))/).map do |match|
        match.compact.first.delete_prefix("\"").delete_suffix("\"").delete_prefix("'").delete_suffix("'")
      end
      search_paths.flat_map { |path| Dir.glob(File.join(path, "*.a")) }
    end
  end
end
