require "base64"
require "compress/zlib"

module ContributorMural
  # Whether two avatar data URIs draw the same picture.
  #
  # GitHub resizes an avatar on request, and which of its servers does the
  # resizing decides how the result is deflated: the same face comes back as
  # one of two PNGs that differ in every compressed byte and in no pixel. The
  # wall embeds the bytes, so a push that happened to reach the other server
  # rewrote the file and committed a picture nobody could tell apart from the
  # last one — on every push, alternating between the two, forever.
  #
  # A PNG is compared with its compression taken off: every chunk except IDAT
  # as written, and the IDAT stream inflated. Anything else, or a PNG that does
  # not parse, is the same picture only when the bytes are.
  module SameImage
    SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    # Past this, inflating is not worth it to save a commit: an avatar at the
    # largest size any style fetches inflates to well under a megabyte.
    MAX_INFLATED = 64 * 1024 * 1024

    def self.same?(a : String, b : String) : Bool
      return true if a == b
      head_a, _, body_a = a.partition(',')
      head_b, _, body_b = b.partition(',')
      return false unless head_a == head_b
      return false unless (png_a = canonical_png(body_a)) && (png_b = canonical_png(body_b))
      png_a == png_b
    end

    # The chunks that are not IDAT, then the inflated image data, or nil for
    # anything that is not a well-formed PNG.
    private def self.canonical_png(base64 : String) : {Array({String, Bytes}), Bytes}?
      bytes = Base64.decode(base64)
      return unless bytes.size > SIGNATURE.size && bytes[0, SIGNATURE.size] == SIGNATURE

      chunks = [] of {String, Bytes}
      idat = IO::Memory.new
      offset = SIGNATURE.size
      while offset + 12 <= bytes.size
        length = IO::ByteFormat::BigEndian.decode(UInt32, bytes[offset, 4]).to_i64
        return if offset + 12 + length > bytes.size
        type = String.new(bytes[offset + 4, 4])
        data = bytes[offset + 8, length]
        offset += 12 + length
        if type == "IDAT"
          idat.write(data)
        else
          chunks << {type, data}
        end
        break if type == "IEND"
      end
      return unless chunks.last?.try(&.[0]) == "IEND"

      idat.rewind
      inflated = IO::Memory.new
      Compress::Zlib::Reader.open(idat) { |zlib| IO.copy(zlib, inflated, MAX_INFLATED + 1) }
      return if inflated.size > MAX_INFLATED
      {chunks, inflated.to_slice}
    rescue Base64::Error | Compress::Zlib::Error | Compress::Deflate::Error | IO::Error
      nil
    end
  end
end
