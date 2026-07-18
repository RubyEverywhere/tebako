/**
 *
 * Copyright (c) 2021-2025 [Ribose Inc](https://www.ribose.com).
 * All rights reserved.
 * This file is a part of the Tebako project.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <memory.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>

#include <string>
#include <cstdint>
#include <limits>
#include <optional>
#include <vector>
#include <stdexcept>
#include <tuple>
#include <fstream>
#include <openssl/sha.h>

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#endif

#include <tebako/tebako-config.h>
#include <tebako/tebako-io.h>

#include <tebako/tebako-version.h>
#include <tebako/tebako-main.h>
#include <tebako/tebako-fs.h>
#include <tebako/tebako-cmdline.h>
#include <tebako/layered-format.h>
#include <tebako/single-file-bundle-format.h>

static int running_miniruby = 0;
static tebako::cmdline_args* args = nullptr;
static std::vector<char> package;

namespace {
struct package_layer {
  std::string mount_point;
  size_t offset;
  size_t size;
};

uint64_t read_little_endian(const std::vector<char>& buffer, size_t& offset, size_t bytes, size_t limit)
{
  if (bytes > sizeof(uint64_t) || offset > limit || bytes > limit - offset) {
    throw std::invalid_argument("Invalid Tebako layer manifest");
  }

  uint64_t value = 0;
  for (size_t index = 0; index < bytes; ++index) {
    value |= static_cast<uint64_t>(static_cast<unsigned char>(buffer[offset + index])) << (index * 8);
  }
  offset += bytes;
  return value;
}

bool valid_layer_mount_point(const std::string& mount_point)
{
  if (mount_point.empty() || mount_point.front() == '/' || mount_point.back() == '/') {
    return false;
  }

  size_t start = 0;
  while (start < mount_point.size()) {
    size_t end = mount_point.find('/', start);
    std::string component = mount_point.substr(start, end - start);
    if (component.empty() || component == "." || component == "..") {
      return false;
    }
    start = end == std::string::npos ? mount_point.size() : end + 1;
  }
  return true;
}

std::string executable_path(const char* argv0)
{
#ifdef _WIN32
  std::vector<char> path(MAX_PATH);
  DWORD length = GetModuleFileNameA(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length > 0 && length < path.size()) {
    return std::string(path.data(), length);
  }
#elif defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::vector<char> path(size);
  if (_NSGetExecutablePath(path.data(), &size) == 0) {
    return std::string(path.data());
  }
#elif defined(__linux__)
  std::vector<char> path(4096);
  ssize_t length = readlink("/proc/self/exe", path.data(), path.size() - 1);
  if (length > 0) {
    return std::string(path.data(), static_cast<size_t>(length));
  }
#endif
  return argv0;
}

std::optional<std::vector<char>> decode_bundle_envelope(const std::vector<char>& container, bool require_runtime)
{
  if (container.size() < tebako::single_file_bundle_format::footer_size) {
    return std::nullopt;
  }

  size_t footer_offset = container.size() - tebako::single_file_bundle_format::footer_size;
  size_t magic_offset = container.size() - tebako::single_file_bundle_format::magic_size;
  if (memcmp(container.data() + magic_offset, tebako::single_file_bundle_format::magic,
             tebako::single_file_bundle_format::magic_size) != 0) {
    return std::nullopt;
  }

  size_t cursor = footer_offset;
  uint64_t application_size = read_little_endian(container, cursor, sizeof(uint64_t), container.size());
  if (application_size == 0 || application_size > footer_offset) {
    throw std::invalid_argument("Invalid single-file bundle application size");
  }
  size_t application_offset = footer_offset - static_cast<size_t>(application_size);
  if (require_runtime && application_offset == 0) {
    throw std::invalid_argument("Invalid single-file bundle runtime size");
  }

  unsigned char digest[SHA256_DIGEST_LENGTH];
  SHA256(reinterpret_cast<const unsigned char*>(container.data() + application_offset),
         static_cast<size_t>(application_size), digest);
  if (memcmp(digest, container.data() + cursor, tebako::single_file_bundle_format::digest_size) != 0) {
    throw std::invalid_argument("Invalid single-file bundle application checksum");
  }
  return std::vector<char>(container.begin() + application_offset, container.begin() + footer_offset);
}

#ifdef __APPLE__
std::optional<std::vector<char>> macho_bundle_application()
{
  unsigned long section_size = 0;
  const uint8_t* section = getsectiondata(&_mh_execute_header, "__TEBAKO", "__app", &section_size);
  if (section == nullptr) {
    return std::nullopt;
  }

  std::vector<char> envelope(reinterpret_cast<const char*>(section),
                             reinterpret_cast<const char*>(section) + section_size);
  auto application = decode_bundle_envelope(envelope, false);
  if (!application.has_value()) {
    throw std::invalid_argument("Invalid Mach-O Tebako application section");
  }
  return application;
}
#endif

std::optional<std::vector<char>> appended_bundle_application(const char* argv0)
{
  std::ifstream file(executable_path(argv0), std::ios::binary | std::ios::ate);
  if (!file) {
    return std::nullopt;
  }
  std::streamsize file_size = file.tellg();
  if (file_size < static_cast<std::streamsize>(tebako::single_file_bundle_format::footer_size)) {
    return std::nullopt;
  }
  file.seekg(0, std::ios::beg);
  std::vector<char> executable(static_cast<size_t>(file_size));
  if (!file.read(executable.data(), file_size)) {
    throw std::invalid_argument("Failed to inspect the Tebako executable");
  }

  return decode_bundle_envelope(executable, true);
}

std::optional<std::vector<char>> single_file_bundle_application(const char* argv0)
{
#ifdef __APPLE__
  auto macho_application = macho_bundle_application();
  if (macho_application.has_value()) {
    return macho_application;
  }
#endif
  return appended_bundle_application(argv0);
}

std::optional<std::vector<package_layer>> parse_package_layers(const std::vector<char>& buffer)
{
  if (buffer.size() < tebako::layered_format::footer_size ||
      memcmp(buffer.data() + buffer.size() - tebako::layered_format::magic_size,
             tebako::layered_format::magic, tebako::layered_format::magic_size) != 0) {
    return std::nullopt;
  }

  size_t footer_offset = buffer.size() - tebako::layered_format::footer_size;
  size_t size_offset = footer_offset;
  uint64_t manifest_size_u64 = read_little_endian(buffer, size_offset, sizeof(uint64_t), buffer.size());
  if (manifest_size_u64 > footer_offset) {
    throw std::invalid_argument("Invalid Tebako layer manifest size");
  }

  size_t manifest_offset = footer_offset - static_cast<size_t>(manifest_size_u64);
  size_t cursor = manifest_offset;
  uint64_t count = read_little_endian(buffer, cursor, sizeof(uint32_t), footer_offset);
  constexpr size_t minimum_record_size = sizeof(uint16_t) + 1 + (2 * sizeof(uint64_t));
  if (count > (footer_offset - cursor) / minimum_record_size) {
    throw std::invalid_argument("Invalid Tebako layer count");
  }
  std::vector<package_layer> layers;
  layers.reserve(static_cast<size_t>(count));

  for (uint64_t index = 0; index < count; ++index) {
    size_t mount_size = static_cast<size_t>(read_little_endian(buffer, cursor, sizeof(uint16_t), footer_offset));
    if (mount_size == 0 || cursor > footer_offset || mount_size > footer_offset - cursor) {
      throw std::invalid_argument("Invalid Tebako layer mount point");
    }
    std::string mount_point(buffer.data() + cursor, mount_size);
    cursor += mount_size;
    if (!valid_layer_mount_point(mount_point)) {
      throw std::invalid_argument("Invalid Tebako layer mount point");
    }

    uint64_t offset_u64 = read_little_endian(buffer, cursor, sizeof(uint64_t), footer_offset);
    uint64_t size_u64 = read_little_endian(buffer, cursor, sizeof(uint64_t), footer_offset);
    if (offset_u64 > manifest_offset || size_u64 == 0 || size_u64 > manifest_offset - offset_u64 ||
        size_u64 > std::numeric_limits<unsigned int>::max()) {
      throw std::invalid_argument("Invalid Tebako layer bounds");
    }
    layers.push_back({mount_point, static_cast<size_t>(offset_u64), static_cast<size_t>(size_u64)});
  }

  if (cursor != footer_offset || layers.empty()) {
    throw std::invalid_argument("Invalid Tebako layer manifest contents");
  }
  return layers;
}

void mount_package_layer(const package_layer& layer, const std::string& mount_point)
{
  size_t separator = layer.mount_point.rfind('/');
  const char* data = package.data() + layer.offset;
  int result;

  if (separator == std::string::npos) {
    result = mount_memfs_at_root(data, static_cast<unsigned int>(layer.size), "auto", layer.mount_point.c_str());
  }
  else {
    std::string parent = layer.mount_point.substr(0, separator);
    std::string folder = layer.mount_point.substr(separator + 1);
    std::string parent_path = mount_point + "/" + parent;
    struct STAT_TYPE st;
    if (folder.empty() || tebako_stat(parent_path.c_str(), &st) != 0) {
      throw std::invalid_argument("Layer parent does not exist in runtime: " + parent_path);
    }
    result = mount_memfs(data, static_cast<unsigned int>(layer.size), "auto", static_cast<unsigned int>(st.st_ino),
                         folder.c_str());
  }

  if (result < 1) {
    throw std::invalid_argument("Failed to mount package layer at " + layer.mount_point);
  }
}

void configure_application_gem_path(const tebako::package_descriptor& descriptor)
{
  std::string ruby_api_version = std::to_string(descriptor.get_ruby_version_major()) + "." +
                                 std::to_string(descriptor.get_ruby_version_minor()) + ".0";
  std::string application_gems = descriptor.get_mount_point() + "/lib/ruby/gems/" + ruby_api_version;
  std::string runtime_gems = std::string(tebako::fs_mount_point) + "/lib/ruby/gems/" + ruby_api_version;
#ifdef _WIN32
  std::string gem_path = application_gems + ";" + runtime_gems;
  _putenv_s("GEM_PATH", gem_path.c_str());
#else
  std::string gem_path = application_gems + ":" + runtime_gems;
  setenv("GEM_PATH", gem_path.c_str(), 1);
#endif
}
}  // namespace

static void tebako_clean(void)
{
  unmount_root_memfs();
  if (args) {
    delete args;
    args = nullptr;
  }
}

extern "C" int tebako_main(int* argc, char*** argv)
{
  int ret = -1, fsret = -1;
  char** new_argv = nullptr;
  char* argv_memory = nullptr;

  if (strstr((*argv)[0], "miniruby") != nullptr) {
    // Ruby build script is designed in such a way that this patch is also applied towards miniruby
    // Just pass through in such case
    ret = 0;
    running_miniruby = -1;
  }
  else {
    std::string mount_point = tebako::fs_mount_point;
    std::string entry_point = tebako::fs_entry_point;
    std::optional<std::string> cwd;
    if (tebako::package_cwd != nullptr) {
      cwd = tebako::package_cwd;
    }
    const void* data = &gfsData[0];
    size_t size = gfsSize;

    try {
      args = new tebako::cmdline_args(*argc, (const char**)*argv);
      args->parse_arguments();
      std::optional<std::vector<package_layer>> layers;
      std::optional<tebako::package_descriptor> descriptor;
      if (args->with_application()) {
        args->process_package();
        descriptor = args->get_descriptor();
        package = std::move(args->get_package());
      }
      else {
        auto embedded_application = single_file_bundle_application((*argv)[0]);
        if (embedded_application.has_value()) {
          package = std::move(*embedded_application);
          descriptor.emplace(package);
        }
      }
      if (descriptor.has_value()) {
        mount_point = descriptor->get_mount_point().c_str();
        entry_point = descriptor->get_entry_point().c_str();
        cwd = descriptor->get_cwd();
        layers = parse_package_layers(package);
        if (!layers.has_value()) {
          data = package.data();
          size = package.size();
        }
        else {
          configure_application_gem_path(*descriptor);
        }
      }

      fsret = mount_root_memfs(data, size, tebako::fs_log_level, nullptr, nullptr, nullptr, nullptr, "auto");
      if (fsret == 0) {
        if (layers.has_value()) {
          for (const auto& layer : *layers) {
            mount_package_layer(layer, mount_point);
          }
        }
        args->process_mountpoints();
        args->build_arguments(mount_point.c_str(), entry_point.c_str());
        *argc = args->get_argc();
        *argv = args->get_argv();
        ret = 0;
        atexit(tebako_clean);
      }
    }
    catch (const std::exception& e) {
      printf("Failed to process command line: %s\n", e.what());
    }

    if (getcwd(tebako::original_cwd, sizeof(tebako::original_cwd)) == nullptr) {
      printf("Failed to get current directory: %s\n", strerror(errno));
      ret = -1;
    }

    if (cwd.has_value()) {
      if (tebako_chdir(cwd->c_str()) != 0) {
        printf("Failed to chdir to '%s' : %s\n", cwd->c_str(), strerror(errno));
        ret = -1;
      }
    }
  }

  if (ret != 0) {
    try {
      printf("Tebako initialization failed\n");
      tebako_clean();
    }
    catch (...) {
      // Nested error, no recovery :(
    }
  }
  return ret;
}

extern "C" const char* tebako_mount_point(void)
{
  return tebako::fs_mount_point;
}

extern "C" const char* tebako_original_pwd(void)
{
  return tebako::original_cwd;
}

extern "C" int tebako_is_running_miniruby(void)
{
  return running_miniruby;
}

#ifdef RB_W32_PRE_33
extern "C" ssize_t rb_w32_pread(int /* fd */, void* /* buf */, size_t /* size */, size_t /* offset */)
{
  return -1;
}
#endif
