# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/tebako/layered_package"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::LayeredPackage do
  around do |example|
    Dir.mktmpdir("tebako-layers") do |directory|
      @directory = directory
      example.run
    end
  end

  it "writes independently addressable layers and a footer manifest" do
    descriptor = File.join(@directory, "descriptor")
    first = File.join(@directory, "first.dwarfs")
    second = File.join(@directory, "second.dwarfs")
    output = File.join(@directory, "application.tebako")
    File.binwrite(descriptor, "descriptor")
    File.binwrite(first, "first")
    File.binwrite(second, "second")

    described_class.write(
      output,
      descriptor: descriptor,
      layers: [
        described_class::Layer.new(mount_point: "local", path: first),
        described_class::Layer.new(mount_point: "lib/ruby/gems/3.4.0", path: second)
      ]
    )

    package = File.binread(output)
    expect(package).to start_with("descriptorfirstsecond")
    expect(package).to end_with(described_class::MAGIC)

    manifest_size = package.byteslice(-16, 8).unpack1("Q<")
    manifest = package.byteslice(package.bytesize - 16 - manifest_size, manifest_size)
    count, mount_size = manifest.unpack("L<S<")
    expect(count).to eq(2)
    expect(manifest.byteslice(6, mount_size)).to eq("local")
  end

  it "rejects unsafe mount points" do
    descriptor = File.join(@directory, "descriptor")
    image = File.join(@directory, "layer.dwarfs")
    File.binwrite(descriptor, "descriptor")
    File.binwrite(image, "image")
    layer = described_class::Layer.new(mount_point: "../local", path: image)

    expect do
      described_class.write(File.join(@directory, "out"), descriptor: descriptor, layers: [layer])
    end.to raise_error(ArgumentError, /Invalid layer mount point/)
  end
end
# rubocop:enable Metrics/BlockLength
