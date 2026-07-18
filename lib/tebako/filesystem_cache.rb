# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
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

require "digest"
require "fileutils"

require_relative "content_manifest"

# Tebako - an executable packager
module Tebako
  # Stores complete DwarFS images by the content and options that produced them.
  class FilesystemCache
    def initialize(cache_dir:, mkdwarfs:, source_dir:, descriptor:, compression_level:)
      @cache_dir = cache_dir
      @mkdwarfs = mkdwarfs
      @source_dir = source_dir
      @descriptor = descriptor
      @compression_level = compression_level
    end

    def fetch(output)
      FileUtils.mkdir_p(@cache_dir)
      cache_path = File.join(@cache_dir, "#{cache_key}.dwarfs")

      File.open("#{cache_path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        next if restore?(cache_path, output)

        yield
        save(cache_path, output)
      end
    end

    private

    def cache_key
      digest = Digest::SHA256.new
      digest << Tebako::ContentManifest.digest_tree(@source_dir)
      digest << "\0#{@compression_level}\0"
      digest << Digest::SHA256.file(@mkdwarfs).hexdigest << "\0"
      digest << File.binread(@descriptor) if @descriptor
      digest.hexdigest
    end

    def restore?(cache_path, output)
      return false unless File.file?(cache_path)

      puts "   ... reusing packaged filesystem #{File.basename(cache_path, ".dwarfs")}"
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.rm_f(output)
      FileUtils.cp(cache_path, output)
      FileUtils.touch(output)
      true
    end

    def save(cache_path, output)
      temporary = "#{cache_path}.#{Process.pid}.tmp"
      FileUtils.cp(output, temporary, preserve: true)
      File.rename(temporary, cache_path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end
  end
end
