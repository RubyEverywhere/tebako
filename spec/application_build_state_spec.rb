# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "tmpdir"

require_relative "../lib/tebako/application_build_state"

# rubocop:disable Metrics
RSpec.describe Tebako::ApplicationBuildState do
  def state(root, metadata = {})
    described_class.new(
      cache_dir: File.join(root, "cache"),
      project_root: File.join(root, "project"),
      implementation_root: File.join(root, "implementation"),
      metadata: { "runtime" => "runtime-v1", "compression" => 5 }.merge(metadata)
    )
  end

  def prepare(root)
    FileUtils.mkdir_p(File.join(root, "project"))
    FileUtils.mkdir_p(File.join(root, "implementation"))
    File.write(File.join(root, "project", "app.rb"), "puts :ok")
    File.write(File.join(root, "implementation", "builder.rb"), "VERSION = 1")
  end

  it "skips the whole application pipeline when the verified output is current" do
    Dir.mktmpdir do |root|
      prepare(root)
      output = File.join(root, "app.tebako")
      expect(state(root).fetch(output) { File.write(output, "package") }).to eq(:miss)
      expect { |probe| state(root).fetch(output, &probe) }.not_to yield_control
    end
  end

  it "rebuilds for project, option, implementation, or output changes" do
    Dir.mktmpdir do |root|
      prepare(root)
      output = File.join(root, "app.tebako")
      state(root).fetch(output) { File.write(output, "package-v1") }

      File.write(File.join(root, "project", "app.rb"), "puts :changed")
      expect { |probe| state(root).fetch(output, &probe) }.to yield_control
      File.write(File.join(root, "project", "app.rb"), "puts :ok")
      expect { |probe| state(root, "compression" => 9).fetch(output, &probe) }.to yield_control
      File.write(File.join(root, "implementation", "builder.rb"), "VERSION = 2")
      expect { |probe| state(root).fetch(output, &probe) }.to yield_control
      File.write(output, "tampered")
      expect { |probe| state(root).fetch(output, &probe) }.to yield_control
    end
  end

  it "serializes concurrent builders for the same output" do
    Dir.mktmpdir do |root|
      prepare(root)
      output = File.join(root, "app.tebako")
      entered = Queue.new
      release = Queue.new
      second_built = false
      first = Thread.new do
        state(root).fetch(output) do
          entered << true
          release.pop
          File.write(output, "package")
        end
      end
      entered.pop
      second = Thread.new { state(root).fetch(output) { second_built = true } }
      release << true
      first.join
      second.join

      expect(second_built).to be(false)
    end
  end
end
# rubocop:enable Metrics
