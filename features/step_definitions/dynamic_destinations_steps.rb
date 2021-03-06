Given(/^I have a dynamic destination "(#{STRING_OR_SYM})" with the following messages on it$/) do |destination, table|
  dest = MessageDriver::Client[test_runner.broker_name].dynamic_destination(destination)
  test_runner.publish_table_to_destination(dest, table)
end

Then(/^I expect to find (#{NUMBER}) messages? on the dynamic destination "(#{STRING_OR_SYM})" with$/) do |count, destination, table|
  expect(test_runner).to have_no_errors
  dest = MessageDriver::Client[test_runner.broker_name].dynamic_destination(destination, passive: true)
  messages = test_runner.fetch_messages(dest)
  expect(messages.size).to eq(count)
  expect(messages).to match_message_table(table)
end
