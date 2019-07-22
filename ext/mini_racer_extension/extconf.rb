require 'mkmf'
require 'fileutils'

IS_DARWIN = RUBY_PLATFORM =~ /darwin/
IS_SOLARIS = RUBY_PLATFORM =~ /solaris/

have_library('pthread')
have_library('objc') if IS_DARWIN
$CPPFLAGS.gsub! /-std=[^\s]+/, ''
$CPPFLAGS += " -Wall" unless $CPPFLAGS.split.include? "-Wall"
$CPPFLAGS += " -g" unless $CPPFLAGS.split.include? "-g"
$CPPFLAGS += " -rdynamic" unless $CPPFLAGS.split.include? "-rdynamic"
$CPPFLAGS += " -fPIC" unless $CPPFLAGS.split.include? "-rdynamic" or IS_DARWIN
$CPPFLAGS += " -std=c++0x"
$CPPFLAGS += " -fpermissive"
$CPPFLAGS += " -fno-omit-frame-pointer"
if enable_config('avx2')
  $CPPFLAGS += " -mavx2"
else
  $CPPFLAGS += " -mssse3"
end

$CPPFLAGS += " -Wno-reserved-user-defined-literal" if IS_DARWIN

$LDFLAGS.insert(0, " -stdlib=libc++ ") if IS_DARWIN

if ENV['CXX']
  puts "SETTING CXX"
  CONFIG['CXX'] = ENV['CXX']
end

CXX11_TEST = <<EOS
#if __cplusplus <= 199711L
#   error A compiler that supports at least C++11 is required in order to compile this project.
#endif
EOS

`echo "#{CXX11_TEST}" | #{CONFIG['CXX']} -std=c++0x -x c++ -E -`
unless $?.success?
  warn <<EOS


WARNING: C++11 support is required for compiling mini_racer. Please make sure
you are using a compiler that supports at least C++11. Examples of such
compilers are GCC 4.7+ and Clang 3.2+.

If you are using Travis, consider either migrating your build to Ubuntu Trusty or
installing GCC 4.8. See mini_racer's README.md for more information.


EOS
end

CONFIG['LDSHARED'] = '$(CXX) -shared' unless IS_DARWIN
if CONFIG['warnflags']
  CONFIG['warnflags'].gsub!('-Wdeclaration-after-statement', '')
  CONFIG['warnflags'].gsub!('-Wimplicit-function-declaration', '')
end

if enable_config('debug') || enable_config('asan')
  CONFIG['debugflags'] << ' -ggdb3 -O0'
end

def fixup_libtinfo
  dirs = %w[/lib64 /usr/lib64 /lib /usr/lib]
  found_v5 = dirs.map { |d| "#{d}/libtinfo.so.5" }.find &File.method(:file?)
  return '' if found_v5
  found_v6 = dirs.map { |d| "#{d}/libtinfo.so.6" }.find &File.method(:file?)
  return '' unless found_v6
  FileUtils.ln_s found_v6, 'gemdir/libtinfo.so.5', :force => true
  "LD_LIBRARY_PATH='#{File.expand_path('gemdir')}:#{ENV['LD_LIBRARY_PATH']}'"
end

def libv8_gem_name
  return "libv8-solaris" if IS_SOLARIS

  is_musl = false
  begin
    is_musl = !!(File.read('/proc/self/maps') =~ /ld-musl-x86_64/)
  rescue; end

  is_musl ? 'libv8-alpine' : 'libv8'
end

# 1) old rubygem versions prefer source gems to binary ones
# ... and their --platform switch is broken too, as it leaves the 'ruby'
# platform in Gem.platforms.
# 2) the ruby binaries distributed with alpine (platform ending in -musl)
# refuse to load binary gems by default
def force_platform_gem
  gem_version = `gem --version`
  return 'gem' unless $?.success?

  if RUBY_PLATFORM != 'x86_64-linux-musl'
    return 'gem' if gem_version.to_f.zero? || gem_version.to_f >= 2.3
    return 'gem' if RUBY_PLATFORM != 'x86_64-linux'
  end

  gem_binary = `which gem`
  return 'gem' unless $?.success?

  ruby = File.foreach(gem_binary.strip).first.sub(/^#!/, '').strip
  unless File.file? ruby
    warn "No valid ruby: #{ruby}"
    return 'gem'
  end

  require 'tempfile'
  file = Tempfile.new('sq_mini_racer')
  file << <<EOS
require 'rubygems'
platforms = Gem.platforms
platforms.reject! { |it| it == 'ruby' }
if platforms.empty?
  platforms << Gem::Platform.new('x86_64-linux')
end
Gem.send(:define_method, :platforms) { platforms }
#{IO.read(gem_binary.strip)}
EOS
  file.close
  "#{ruby} '#{file.path}'"
end

LIBV8_VERSION = '7.3.492.27.1'
libv8_glob = "**/*-#{LIBV8_VERSION}-*/**/libv8.rb"
libv8_rb = Dir.glob(libv8_glob).first
FileUtils.mkdir_p('gemdir')
unless libv8_rb
  gem_name = libv8_gem_name
  cmd = "#{fixup_libtinfo} #{force_platform_gem} install --version '= #{LIBV8_VERSION}' --install-dir gemdir #{gem_name}"
  puts "Will try downloading #{gem_name} gem: #{cmd}"
  `#{cmd}`
  unless $?.success?
    warn <<EOS

WARNING: Could not download a private copy of the libv8 gem. Please make
sure that you have internet access and that the `gem` binary is available.

EOS
  end

  libv8_rb = Dir.glob(libv8_glob).first
  unless libv8_rb
    warn <<EOS

WARNING: Could not find libv8 after the local copy of libv8 having supposedly
been installed.

EOS
  end
end

if libv8_rb
  $:.unshift(File.dirname(libv8_rb) + '/../ext')
  $:.unshift File.dirname(libv8_rb)
end

require 'libv8'
Libv8.configure_makefile

if enable_config('asan')
  $CPPFLAGS.insert(0, " -fsanitize=address ")
  $LDFLAGS.insert(0, " -fsanitize=address ")
end

create_makefile 'sq_mini_racer_extension'
