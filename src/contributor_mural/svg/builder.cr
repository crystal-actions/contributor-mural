require "html"

module ContributorMural
  module SVG
    def self.escape(value : String) : String
      HTML.escape(value)
    end

    # Formats a coordinate with at most two decimals and no trailing zeros,
    # keeping output compact and golden files stable.
    def self.num(value : Float64) : String
      formatted = ("%.2f" % value).rstrip('0').rstrip('.')
      formatted.in?("", "-0") ? "0" : formatted
    end

    def self.num(value : Int) : String
      value.to_s
    end

    def self.document(width : Int | Float64, height : Int | Float64,
                      & : String::Builder ->) : String
      String.build do |io|
        io << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{num(width)}" height="#{num(height)}" viewBox="0 0 #{num(width)} #{num(height)}">\n)
        yield io
        io << "</svg>\n"
      end
    end
  end
end
