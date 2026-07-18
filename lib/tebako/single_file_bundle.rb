# frozen_string_literal: true

# Copyright (c) 2026 [RubyEverywhere](https://rubyeverywhere.com).
# All rights reserved.
# This file is a part of the Tebako project.

require "digest"
require "fileutils"
require "securerandom"

require_relative "build_reporter"
require_relative "generated/single_file_bundle_format"
require_relative "layered_package"

# rubocop:disable Metrics
# Tebako - an executable packager
module Tebako
  # Atomically combines a layered application with a reusable runtime executable.
  module SingleFileBundle
    Format = Tebako::Generated::SingleFileBundleFormat
    MACHO_64_MAGIC = "\xcf\xfa\xed\xfe".b
    MACHO_SEGMENT_64 = 0x19
    MACHO_HEADER_SIZE = 32
    MACHO_SEGMENT_SIZE = 72
    MACHO_SECTION_SIZE = 80
    MACHO_SEGMENT = "__TEBAKO"
    MACHO_SECTION = "__app"

    Inspection = Struct.new(:format, :container, :major_version, :minor_version, :runtime_size, :application_size,
                            :application_sha256, :byte_size, :application, keyword_init: true) do
      def to_h
        {
          "format" => format,
          "container" => container,
          "major_version" => major_version,
          "minor_version" => minor_version,
          "runtime_size" => runtime_size,
          "application_size" => application_size,
          "application_sha256" => application_sha256,
          "size" => byte_size,
          "application" => application.to_h
        }
      end
    end

    class << self
      def bundle?(path)
        return false unless File.file?(path)

        data = File.binread(path)
        appended_bundle?(data) || !macho_envelope(data).nil?
      rescue SystemCallError
        false
      end

      def write(output, runtime:, application:, assembler: nil)
        application_inspection = Tebako::LayeredPackage.inspect(application)
        temporary = "#{output}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
        payload = "#{temporary}.payload"
        FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
        write_envelope(payload, application, application_inspection.sha256)
        if assembler
          assembler.call(temporary, payload)
        else
          File.open(temporary, "wb") do |bundle|
            File.open(runtime, "rb") { |source| IO.copy_stream(source, bundle) }
            File.open(payload, "rb") { |source| IO.copy_stream(source, bundle) }
            bundle.flush
            bundle.fsync
          end
        end
        FileUtils.chmod(File.stat(runtime).mode & 0o7777, temporary)
        inspection = inspect(temporary)
        File.rename(temporary, output)
        report(runtime, application, output, inspection.container)
        output
      ensure
        FileUtils.rm_f(temporary) if temporary
        FileUtils.rm_f(payload) if payload
      end

      def inspect(path)
        data = File.binread(path)
        envelope, runtime_size, container = locate_envelope(data)
        application, _, digest = decode(envelope, require_runtime: false)
        actual_digest = Digest::SHA256.hexdigest(application)
        raise ArgumentError, "Single-file bundle application checksum is invalid" unless actual_digest == digest

        Inspection.new(
          format: "single_file_bundle",
          container: container,
          major_version: Format::MAJOR_VERSION,
          minor_version: Format::MINOR_VERSION,
          runtime_size: runtime_size,
          application_size: application.bytesize,
          application_sha256: digest,
          byte_size: data.bytesize,
          application: Tebako::LayeredPackage.inspect_bytes(application)
        )
      end

      def application_bytes(path)
        data = File.binread(path)
        envelope, = locate_envelope(data)
        application, = decode(envelope, require_runtime: false)
        application
      end

      private

      def write_envelope(payload, application, digest)
        File.open(payload, "wb") do |bundle|
          File.open(application, "rb") { |source| IO.copy_stream(source, bundle) }
          bundle.write([File.size(application)].pack("Q<"))
          bundle.write([digest].pack("H*"))
          bundle.write(Format::MAGIC)
          bundle.flush
          bundle.fsync
        end
      end

      def locate_envelope(data)
        if data.byteslice(0, 4) == MACHO_64_MAGIC
          envelope, offset = macho_envelope(data)
          return [envelope, offset, "macho_section"] if envelope
        end

        if appended_bundle?(data)
          application, runtime_size, = decode(data, require_runtime: true)
          envelope_size = application.bytesize + Format::FOOTER_SIZE
          return [data.byteslice(runtime_size, envelope_size), runtime_size, "appended"]
        end

        raise ArgumentError, "File is not a supported single-file bundle"
      end

      def appended_bundle?(data)
        data.bytesize >= Format::FOOTER_SIZE && data.end_with?(Format::MAGIC)
      end

      def decode(data, require_runtime:)
        raise ArgumentError, "File is too small for a single-file bundle" if data.bytesize < Format::FOOTER_SIZE
        raise ArgumentError, "File is not a supported single-file bundle" unless data.end_with?(Format::MAGIC)

        footer = data.bytesize - Format::FOOTER_SIZE
        application_size = data.byteslice(footer, 8).unpack1("Q<")
        digest = data.byteslice(footer + 8, Format::DIGEST_SIZE).unpack1("H*")
        raise ArgumentError, "Single-file bundle application size is invalid" if application_size > footer

        runtime_size = footer - application_size
        if require_runtime && runtime_size.zero?
          raise ArgumentError,
                "Single-file bundle runtime is empty"
        end

        [data.byteslice(runtime_size, application_size), runtime_size, digest]
      end

      def macho_envelope(data) # rubocop:disable Metrics/MethodLength
        return unless data.byteslice(0, 4) == MACHO_64_MAGIC
        return if data.bytesize < MACHO_HEADER_SIZE

        command_count = read_uint32(data, 16)
        commands_size = read_uint32(data, 20)
        cursor = MACHO_HEADER_SIZE
        commands_end = cursor + commands_size
        return if commands_end > data.bytesize

        command_count.times do
          return if cursor + 8 > commands_end

          command = read_uint32(data, cursor)
          command_size = read_uint32(data, cursor + 4)
          return if command_size < 8 || cursor + command_size > commands_end

          section = macho_section(data, cursor, command_size) if command == MACHO_SEGMENT_64
          return section if section

          cursor += command_size
        end
        nil
      end # rubocop:enable Metrics/MethodLength

      def macho_section(data, command_offset, command_size)
        return if command_size < MACHO_SEGMENT_SIZE
        return unless macho_name(data.byteslice(command_offset + 8, 16)) == MACHO_SEGMENT

        section_count = read_uint32(data, command_offset + 64)
        return if section_count > (command_size - MACHO_SEGMENT_SIZE) / MACHO_SECTION_SIZE

        section_count.times do |index|
          offset = command_offset + MACHO_SEGMENT_SIZE + (index * MACHO_SECTION_SIZE)
          next unless macho_name(data.byteslice(offset, 16)) == MACHO_SECTION

          file_offset = read_uint32(data, offset + 48)
          size = read_uint64(data, offset + 40)
          return nil if size > data.bytesize || file_offset > data.bytesize - size

          return [data.byteslice(file_offset, size), file_offset]
        end
        nil
      end

      def macho_name(value)
        value.to_s.split("\0", 2).first
      end

      def read_uint32(data, offset)
        data.byteslice(offset, 4).unpack1("L<")
      end

      def read_uint64(data, offset)
        data.byteslice(offset, 8).unpack1("Q<")
      end

      def report(runtime, application, output, container)
        Tebako::BuildReporter.record(
          stage: "bundle_assembly",
          status: "rebuilt",
          reason: "reused runtime and layered application were assembled into one executable",
          details: {
            "runtime_bytes" => File.size(runtime),
            "application_bytes" => File.size(application),
            "output_bytes" => File.size(output),
            "container" => container
          }
        )
      end
    end
  end
end
# rubocop:enable Metrics
