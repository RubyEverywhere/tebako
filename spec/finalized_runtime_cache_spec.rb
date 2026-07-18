# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/tebako/finalized_runtime_cache"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::FinalizedRuntimeCache do
  def descriptor(identity = "tebako-runtime-v1-test")
    Tebako::RuntimeDescriptor.new(
      "schema_version" => 1,
      "runtime_identity" => identity,
      "ruby_version" => "4.0.6",
      "ruby_api_version" => "4.0.0",
      "platform" => RUBY_PLATFORM,
      "package_formats" => { "layered" => 1 }
    )
  end

  it "builds once and restores a verified finalized runtime" do
    Dir.mktmpdir do |directory|
      cache = described_class.new(cache_dir: directory, descriptor: descriptor)
      calls = 0

      first = cache.fetch do |runtime|
        calls += 1
        File.binwrite(runtime, "native runtime")
        descriptor.write(Tebako::RuntimeDescriptor.path_for(runtime))
      end
      second = cache.fetch { calls += 1 }

      expect(calls).to eq(1)
      expect(second).to eq(first)
      expect(File.binread(second)).to eq("native runtime")
    end
  end

  it "rejects corruption and atomically rebuilds the artifact" do
    Dir.mktmpdir do |directory|
      cache = described_class.new(cache_dir: directory, descriptor: descriptor)
      runtime = cache.fetch do |path|
        File.binwrite(path, "first")
        descriptor.write(Tebako::RuntimeDescriptor.path_for(path))
      end
      File.binwrite(runtime, "corrupt")

      rebuilt = cache.fetch do |path|
        File.binwrite(path, "second")
        descriptor.write(Tebako::RuntimeDescriptor.path_for(path))
      end

      expect(File.binread(rebuilt)).to eq("second")
    end
  end

  it "keeps runtime identities isolated" do
    Dir.mktmpdir do |directory|
      first_descriptor = descriptor("tebako-runtime-v1-first")
      second_descriptor = descriptor("tebako-runtime-v1-second")
      first = described_class.new(cache_dir: directory, descriptor: first_descriptor).fetch do |path|
        File.binwrite(path, "first")
        first_descriptor.write(Tebako::RuntimeDescriptor.path_for(path))
      end
      second = described_class.new(cache_dir: directory, descriptor: second_descriptor).fetch do |path|
        File.binwrite(path, "second")
        second_descriptor.write(Tebako::RuntimeDescriptor.path_for(path))
      end

      expect(first).not_to eq(second)
      expect(File.binread(first)).to eq("first")
      expect(File.binread(second)).to eq("second")
    end
  end
end
# rubocop:enable Metrics/BlockLength
