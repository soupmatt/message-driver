RSpec.shared_examples 'an adapter' do
  describe '#new_context' do
    it 'returns a MessageDriver::Adapters::ContextBase' do
      expect(subject.new_context).to be_a MessageDriver::Adapters::ContextBase
    end
  end

  describe '#stop' do
    it 'invalidates all the adapter contexts' do
      ctx1 = subject.new_context
      ctx2 = subject.new_context
      subject.stop
      expect(ctx1).to_not be_valid
      expect(ctx2).to_not be_valid
    end
  end

  describe '#broker' do
    it 'returns the broker associated with the adapter' do
      expect(subject.broker).to be(broker)
    end
  end

  it { expect(subject.class).to respond_to(:new).with(1..2).arguments }
  it { is_expected.to respond_to(:build_context).with(0).arguments }
end
