module ContributorMural
  # The faces already on the wall, taken back off the file this run is about to
  # replace.
  #
  # An avatar host that throttles, blips, or answers 404 for a minute takes
  # people off the mural, and the run then commits that — so the picture
  # regresses over a failure which has usually fixed itself by the time anyone
  # looks at it. Retrying is not the answer here; the retries already happened
  # and the fetcher gave up.
  #
  # The previous output is the cache. Every avatar in it is base64 in the
  # document, inside the link of the person it belongs to, so a wall that has
  # been rendered once already holds everything needed to redraw it. Nothing
  # extra is written, nothing has to be restored between runs, and a face is
  # only ever reused for someone this run has already decided belongs on the
  # wall — a person dropped by `exclude` or `limit` is never read back in.
  module AvatarSalvage
    LINK_OPEN = %(<a href=")
    # Narrower than `href="data:` on purpose: the only data URI this program
    # emits is an image, and anything else under that prefix is not ours.
    DATA_OPEN = %(href="data:image/)
    HREF_OPEN = %(href=")
    QUOTE     = '"'

    # A data URI longer than this is not one we wrote — the fetcher caps a
    # single avatar at 8 MB before it is base64-encoded.
    MAX_URI = 12 * 1024 * 1024

    # Exactly the shape `Embedder#fetch_missing` builds, and nothing else.
    #
    # What comes back from here is written into an `href` attribute verbatim,
    # the way a freshly encoded one is — which is safe only because base64 and
    # a known content type cannot carry `&`, `<` or a quote. A previous wall is
    # a file on disk, though: hand-edited, merge-mangled, or left half-written
    # by a killed job, it can hold anything between those two quotes, and one
    # bare `&` costs the whole document rather than one label. Salvage is a new
    # route into the markup, so it is checked at the door instead of trusted
    # for having been ours once.
    VALID_URI = /\Adata:image\/[a-z0-9.+-]+;base64,[A-Za-z0-9+\/=]*\z/

    # Link (as it appears in the markup) => data URI, for every person the
    # given outputs already carry.
    def self.read(workspace : String, paths : Array(String)) : Hash(String, String)
      found = {} of String => String
      paths.each do |path|
        # SVG only: a PNG has been rasterized, and the avatars in it stopped
        # being addressable the moment they became pixels.
        next unless path.ends_with?(".svg")
        full = File.join(workspace, path)
        next unless File.file?(full)
        begin
          scan(File.read(full), found)
        rescue IO::Error
          # An unreadable previous wall is a cache miss, not a failure: the run
          # is about to write over it either way.
          next
        end
      end
      found
    end

    # `<a href="LINK" …>` … `<image href="data:image/…;base64,…"`. Every style
    # wraps one person in one link and draws their avatar inside it, so the
    # first data URI after a link belongs to that link, and a link carrying
    # none before the next one contributes nothing.
    #
    # Scanned by byte offset rather than by character: a single non-ASCII
    # display name anywhere in the document turns character indexing into a
    # walk from the start of the string, once per lookup, over a file that is
    # mostly megabytes of base64.
    private def self.scan(svg : String, found : Hash(String, String)) : Nil
      cursor = 0
      while open = svg.byte_index(LINK_OPEN, cursor)
        link_start = open + LINK_OPEN.bytesize
        link_end = svg.byte_index(QUOTE, link_start)
        break unless link_end
        cursor = link_end + 1

        # Bounded by the next link so a person whose avatar is missing from the
        # old file cannot adopt the next person's face.
        stop = svg.byte_index(LINK_OPEN, cursor) || svg.bytesize
        data = svg.byte_index(DATA_OPEN, cursor)
        next unless data && data < stop

        uri_start = data + HREF_OPEN.bytesize
        uri_end = svg.byte_index(QUOTE, uri_start)
        next unless uri_end && uri_end - uri_start <= MAX_URI
        cursor = uri_end + 1

        uri = svg.byte_slice(uri_start, uri_end - uri_start)
        next unless uri.matches?(VALID_URI)

        # First one wins, the way the first output listed is the one whose
        # dimensions get reported: several targets hold the same faces at
        # different sizes, and reading them all would only overwrite each
        # entry with its own twin.
        found[svg.byte_slice(link_start, link_end - link_start)] ||= uri
      end
    end
  end
end
