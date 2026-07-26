require "spec"
require "../src/contributor_mural"

module SpecHelper
  FIXTURES = Path[__DIR__] / "fixtures"

  def self.fixture(*parts : String) : String
    (FIXTURES / Path[*parts]).to_s
  end
end
