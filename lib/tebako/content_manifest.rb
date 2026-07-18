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
require "json"

# Tebako - an executable packager
module Tebako
  # Builds deterministic, content-addressed manifests for package inputs.
  class ContentManifest
    VERSION = 1
    BUFFER_SIZE = 1024 * 1024

    class << self
      def digest_tree(root, excluded: [])
        root = File.expand_path(root)
        exclusions = excluded.compact.map { |path| File.expand_path(path) }
        digest = Digest::SHA256.new
        digest_directory(digest, root, "", exclusions)
        digest.hexdigest
      end

      def stat_digest_tree(root, excluded: [])
        root = File.expand_path(root)
        exclusions = excluded.compact.map { |path| File.expand_path(path) }
        digest = Digest::SHA256.new
        digest_stat_directory(digest, root, "", exclusions)
        digest.hexdigest
      end

      def serialize(root:, metadata:, excluded: [])
        JSON.generate(
          "version" => VERSION,
          "root" => File.expand_path(root),
          "tree" => digest_tree(root, excluded: excluded),
          "metadata" => metadata.transform_keys(&:to_s).sort.to_h
        )
      end

      private

      def digest_directory(digest, root, relative, exclusions)
        absolute = relative.empty? ? root : File.join(root, relative)
        return if excluded?(absolute, exclusions)

        stat = File.lstat(absolute)
        add_entry(digest, relative, stat, absolute)
        return unless stat.directory?

        Dir.children(absolute).sort.each do |name|
          child = relative.empty? ? name : File.join(relative, name)
          digest_directory(digest, root, child, exclusions)
        end
      end

      def digest_stat_directory(digest, root, relative, exclusions)
        absolute = relative.empty? ? root : File.join(root, relative)
        return if excluded?(absolute, exclusions)

        stat = File.lstat(absolute)
        add_stat_entry(digest, relative, stat, absolute)
        return unless stat.directory?

        Dir.children(absolute).sort.each do |name|
          child = relative.empty? ? name : File.join(relative, name)
          digest_stat_directory(digest, root, child, exclusions)
        end
      end

      def add_stat_entry(digest, relative, stat, absolute)
        digest << [relative.b, stat.ftype, stat.mode.to_s].join("\0") << "\0"
        add_stat_content(digest, stat, absolute)
        digest << "\0"
      end

      def add_stat_content(digest, stat, absolute)
        return digest << stat.size.to_s << "\0" << stat.mtime.to_r.to_s if stat.file?
        return digest << File.readlink(absolute).b if stat.symlink?

        digest
      end

      def add_entry(digest, relative, stat, absolute)
        digest << relative.b << "\0" << stat.ftype << "\0" << stat.mode.to_s << "\0"
        add_entry_content(digest, stat, absolute)
        digest << "\0"
      end

      def add_entry_content(digest, stat, absolute)
        return digest << File.readlink(absolute).b if stat.symlink?
        return digest_file(digest, absolute) if stat.file?

        digest
      end

      def digest_file(digest, path)
        File.open(path, "rb") do |file|
          digest << file.read(BUFFER_SIZE) until file.eof?
        end
      end

      def excluded?(path, exclusions)
        exclusions.any? { |excluded| path == excluded || path.start_with?("#{excluded}#{File::SEPARATOR}") }
      end
    end
  end
end
