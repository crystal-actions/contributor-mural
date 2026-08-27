require "spec"
require "../src/contributor_mural"

module SpecHelper
  FIXTURES = Path[__DIR__] / "fixtures"

  def self.fixture(*parts : String) : String
    (FIXTURES / Path[*parts]).to_s
  end
end

# Annotations are workflow output, not spec output: a source that narrates what
# it truncated, or a resolver that warns about a `limit`, would otherwise print
# through the middle of the progress dots. Examples that assert on an annotation
# install a buffer of their own and read it back.
Spec.before_each { ContributorMural::Annotations.io = IO::Memory.new }
Spec.after_each { ContributorMural::Annotations.io = STDOUT }
