# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/tebako/single_file_bundle"

# rubocop:disable Metrics/BlockLength
RSpec.describe Tebako::SingleFileBundle do
  around do |example|
    Dir.mktmpdir("tebako-single-file") do |directory|
      @directory = directory
      example.run
    end
  end

  def application # rubocop:disable Metrics/MethodLength
    descriptor = File.join(@directory, "descriptor")
    layer = File.join(@directory, "application.dwarfs")
    output = File.join(@directory, "application.tebako")
    File.binwrite(descriptor, "descriptor")
    File.binwrite(layer, "application")
    Tebako::LayeredPackage.write(
      output,
      descriptor: descriptor,
      layers: [Tebako::LayeredPackage::Layer.new(mount_point: "local", path: layer)]
    )
    output
  end

  def macho_with_application_envelope(envelope) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    header_size = described_class::MACHO_HEADER_SIZE
    segment_size = described_class::MACHO_SEGMENT_SIZE
    section_size = described_class::MACHO_SECTION_SIZE
    command_size = segment_size + section_size
    payload_offset = header_size + command_size
    header = [
      0xfeedfacf, 0x0100000c, 0, 2, 1, command_size, 0, 0
    ].pack("L<8")
    segment = [described_class::MACHO_SEGMENT].pack("a16")
    segment = [described_class::MACHO_SEGMENT_64, command_size].pack("L<2") +
              segment +
              [0, envelope.bytesize, payload_offset, envelope.bytesize].pack("Q<4") +
              [7, 3, 1, 0].pack("L<4")
    section = [described_class::MACHO_SECTION, described_class::MACHO_SEGMENT].pack("a16a16") +
              [0, envelope.bytesize].pack("Q<2") +
              [payload_offset, 0, 0, 0, 0, 0, 0, 0].pack("L<8")
    "#{header}#{segment}#{section}#{envelope}link-edit-data"
  end

  it "assembles one executable and preserves its mode" do
    runtime = File.join(@directory, "runtime")
    output = File.join(@directory, "standalone")
    File.binwrite(runtime, "native runtime")
    FileUtils.chmod(0o755, runtime)

    described_class.write(output, runtime: runtime, application: application)
    inspection = described_class.inspect(output)

    expect(described_class.bundle?(output)).to be(true)
    expect(File.binread(output)).to start_with("native runtime")
    expect(File.stat(output).mode & 0o777).to eq(0o755)
    expect(inspection.to_h).to include(
      "format" => "single_file_bundle",
      "container" => "appended",
      "runtime_size" => "native runtime".bytesize
    )
    expect(inspection.application.layers.map(&:mount_point)).to eq(["local"])
  end

  it "rejects application corruption" do
    runtime = File.join(@directory, "runtime")
    output = File.join(@directory, "standalone")
    File.binwrite(runtime, "native runtime")
    described_class.write(output, runtime: runtime, application: application)
    runtime_size = "native runtime".bytesize
    File.open(output, "r+b") do |file|
      file.seek(runtime_size)
      file.write("X")
    end

    expect { described_class.inspect(output) }.to raise_error(ArgumentError, /checksum/)
  end

  it "rejects truncation and invalid application sizes" do
    runtime = File.join(@directory, "runtime")
    output = File.join(@directory, "standalone")
    File.binwrite(runtime, "native runtime")
    described_class.write(output, runtime: runtime, application: application)
    File.truncate(output, File.size(output) - 1)
    expect(described_class.bundle?(output)).to be(false)

    invalid = ["runtime", [1000].pack("Q<"), "\0" * 32, described_class::Format::MAGIC].join
    File.binwrite(output, invalid)
    expect { described_class.inspect(output) }.to raise_error(ArgumentError, /size/)
  end

  it "assembles and inspects a Mach-O section container" do
    runtime = File.join(@directory, "runtime")
    output = File.join(@directory, "standalone")
    File.binwrite(runtime, "native runtime")
    FileUtils.chmod(0o755, runtime)
    assembler = lambda do |target, envelope|
      File.binwrite(target, macho_with_application_envelope(File.binread(envelope)))
    end

    described_class.write(output, runtime: runtime, application: application, assembler: assembler)
    inspection = described_class.inspect(output)

    expect(described_class.bundle?(output)).to be(true)
    expect(inspection.container).to eq("macho_section")
    expect(inspection.application.layers.map(&:mount_point)).to eq(["local"])
    expect(File.binread(output)).not_to end_with(described_class::Format::MAGIC)
  end

  it "rejects corruption inside a Mach-O application section" do
    runtime = File.join(@directory, "runtime")
    output = File.join(@directory, "standalone")
    File.binwrite(runtime, "native runtime")
    assembler = lambda do |target, envelope|
      File.binwrite(target, macho_with_application_envelope(File.binread(envelope)))
    end
    described_class.write(output, runtime: runtime, application: application, assembler: assembler)
    inspection = described_class.inspect(output)
    File.open(output, "r+b") do |file|
      file.seek(inspection.runtime_size)
      file.write("X")
    end

    expect { described_class.inspect(output) }.to raise_error(ArgumentError, /checksum/)
  end
end
# rubocop:enable Metrics/BlockLength
