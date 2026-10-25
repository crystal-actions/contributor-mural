require "compress/zlib"
require "digest/crc32"

# A real 2×2 grayscale PNG whose pixels are `pixels` and whose IDAT is deflated
# at `level`: the same picture in different bytes, the way two avatar servers
# hand it back.
def tiny_png(pixels : Bytes = Bytes[0, 255, 255, 0], level : Int32 = 9) : Bytes
  raw = IO::Memory.new
  2.times { |row| raw.write_byte(0_u8); raw.write(pixels[row * 2, 2]) }
  idat = IO::Memory.new
  Compress::Zlib::Writer.open(idat, level: level, &.write(raw.to_slice))

  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  ihdr = IO::Memory.new
  ihdr.write_bytes(2_u32, IO::ByteFormat::BigEndian)
  ihdr.write_bytes(2_u32, IO::ByteFormat::BigEndian)
  ihdr.write(Bytes[8, 0, 0, 0, 0])
  {"IHDR" => ihdr.to_slice, "IDAT" => idat.to_slice, "IEND" => Bytes.empty}.each do |type, data|
    io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
    io.write(type.to_slice)
    io.write(data)
    io.write_bytes(Digest::CRC32.update(data, Digest::CRC32.checksum(type)), IO::ByteFormat::BigEndian)
  end
  io.to_slice
end

def png_uri(png : Bytes, type : String = "image/png") : String
  "data:#{type};base64,#{Base64.strict_encode(png)}"
end

# Hands every login the same real PNG, deflated at `level`.
class PngAvatarSource < ContributorMural::AvatarSource
  def initialize(@level : Int32, @pixels : Bytes = Bytes[0, 255, 255, 0])
  end

  def url_for(user : ContributorMural::ResolvedUser, size : Int32) : String
    "png://#{user.login}/#{size}"
  end

  def fetch(user : ContributorMural::ResolvedUser, size : Int32) : {Bytes, String}
    {tiny_png(@pixels, @level), "image/png"}
  end
end
