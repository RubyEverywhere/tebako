# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/filesystem_cache"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::FilesystemCache do
  def cache_for(root, source, mkdwarfs)
    described_class.new(
      cache_dir: File.join(root, "cache"),
      mkdwarfs: mkdwarfs,
      source_dir: source,
      descriptor: nil,
      compression_level: 5
    )
  end

  it "reuses a complete filesystem with identical content" do
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      output = File.join(root, "fs.bin")
      mkdwarfs = File.join(root, "mkdwarfs")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "app.rb"), "puts :ok")
      File.write(mkdwarfs, "writer-v1")
      cache = cache_for(root, source, mkdwarfs)

      cache.fetch(output) { File.write(output, "image-v1") }
      cache_path = Dir.glob(File.join(root, "cache", "*.dwarfs")).first
      FileUtils.touch(cache_path, mtime: Time.at(1))
      FileUtils.rm_f(output)
      expect { |probe| cache.fetch(output, &probe) }.not_to yield_control

      expect(File.binread(output)).to eq("image-v1")
      expect(File.mtime(output)).to be > Time.at(1)
    end
  end

  it "misses when source content changes" do
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      output = File.join(root, "fs.bin")
      mkdwarfs = File.join(root, "mkdwarfs")
      FileUtils.mkdir_p(source)
      path = File.join(source, "app.rb")
      File.write(path, "puts :ok")
      File.write(mkdwarfs, "writer-v1")
      cache = cache_for(root, source, mkdwarfs)
      cache.fetch(output) { File.write(output, "image-v1") }

      File.write(path, "puts :changed")
      expect do |probe|
        cache_for(root, source, mkdwarfs).fetch(output, &probe)
      end.to yield_control
    end
  end
end
# rubocop:enable Metrics/BlockLength
