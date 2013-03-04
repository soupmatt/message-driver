require 'spec_helper'

describe MessageDriver::Adapter::Base do
  class TestAdapter < described_class
    def initialize(configuration)

    end
  end
  subject { TestAdapter.new({}) }

  describe "#send_message" do
    it "raises an error" do
      expect {
        subject.send_message(:destination, {foo: "bar"})
      }.to raise_error "Must be implemented in subclass"
    end
  end

  describe "#pop_message" do
    it "raises an error" do
      expect {
        subject.pop_message(:destination)
      }.to raise_error "Must be implemented in subclass"
    end
  end
end
