require "./spec_helper"
require "./support/png"

describe ContributorMural::SameImage do
  it "takes two deflations of the same PNG for one picture" do
    fast, small = tiny_png(level: 1), tiny_png(level: 9)
    fast.should_not eq(small)
    ContributorMural::SameImage.same?(png_uri(fast), png_uri(small)).should be_true
  end

  it "tells different pixels apart" do
    a = png_uri(tiny_png(Bytes[0, 255, 255, 0]))
    b = png_uri(tiny_png(Bytes[0, 255, 255, 1]))
    ContributorMural::SameImage.same?(a, b).should be_false
  end

  it "tells a change of declared type apart" do
    png = tiny_png
    ContributorMural::SameImage.same?(png_uri(png, "image/gif"), png_uri(png)).should be_false
  end

  it "compares anything that is not a PNG by its bytes" do
    a = "data:image/jpeg;base64,#{Base64.strict_encode("one")}"
    b = "data:image/jpeg;base64,#{Base64.strict_encode("two")}"
    ContributorMural::SameImage.same?(a, a).should be_true
    ContributorMural::SameImage.same?(a, b).should be_false
  end

  it "takes a truncated PNG for a different picture" do
    whole = tiny_png(level: 1)
    cut = whole[0, whole.size - 12]
    ContributorMural::SameImage.same?(png_uri(cut), png_uri(tiny_png(level: 9))).should be_false
  end
end
