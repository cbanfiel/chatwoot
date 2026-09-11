# Proves every patch in deploy/patches is actually loaded and behaving.
# Read-only: creates no messages, sends nothing to customers.
# Run with: make run FILE=scripts/verify_patches.rb
failures = []
check = lambda do |name, expected, actual|
  ok = expected == actual
  failures << "#{name}: expected #{expected.inspect}, got #{actual.inspect}" unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{name}"
end

# --- imap_lock_to_single_conversation.rb
check.call('ImapMailbox#find_or_create_conversation is patched', false,
           Imap::ImapMailbox.instance_method(:find_or_create_conversation).owner == Imap::ImapMailbox)

email_inbox = Inbox.find_by(channel_type: 'Channel::Email')
check.call('email inbox locked to a single conversation', true, email_inbox&.lock_to_single_conversation)

if email_inbox
  contact_inbox = email_inbox.contact_inboxes.joins(:conversations).first
  if contact_inbox
    mailbox = Imap::ImapMailbox.allocate
    mailbox.instance_variable_set(:@inbox, email_inbox)
    mailbox.instance_variable_set(:@contact_inbox, contact_inbox)
    before = Conversation.count
    reused = mailbox.send(:find_or_create_conversation)
    check.call('repeat email reuses the contact conversation', contact_inbox.conversations.last.id, reused.id)
    check.call('no conversation created while checking', 0, Conversation.count - before)
  end
end

# --- channel_aware_handoff_message.rb
[Captain::Conversation::ResponseBuilderJob, Captain::InboxPendingConversationsResolutionJob].each do |klass|
  check.call("#{klass}#create_handoff_message is patched", false,
             klass.instance_method(:create_handoff_message).owner == klass)
end

assistant = Captain::Assistant.first
chat = Inbox.find_by(channel_type: 'Channel::WebWidget')&.conversations&.last
email = email_inbox&.conversations&.last

if assistant && chat && email
  check.call('chat handoff uses the chat copy', assistant.config['handoff_message_chat'],
             ChannelAwareHandoffMessage.for(assistant, chat))
  check.call('email handoff falls through to upstream', nil,
             ChannelAwareHandoffMessage.for(assistant, email))

  before = Message.count
  sent = {}
  { 'chat' => chat, 'email' => email }.each do |label, conversation|
    job = Captain::Conversation::ResponseBuilderJob.allocate
    job.instance_variable_set(:@assistant, assistant)
    job.instance_variable_set(:@conversation, conversation)
    job.define_singleton_method(:create_outgoing_message) { |content, **| sent[label] = content }
    job.send(:create_handoff_message)
  end
  check.call('chat conversation would send the ticket copy',
             assistant.config['handoff_message_chat'], sent['chat'])
  check.call('email conversation would send the email copy',
             assistant.config['handoff_message'], sent['email'])
  check.call('no message created while checking', 0, Message.count - before)
end

# --- skip_out_of_office_on_custom_handoff.rb
ooo = MessageTemplates::Template::OutOfOffice
check.call('OutOfOffice.perform_if_applicable is patched', false,
           ooo.method(:perform_if_applicable).owner == ooo.singleton_class)

handoff_inbox = Inbox.all.find { |i| i.captain_assistant&.config&.dig('handoff_message').present? }
handoff_conversation = handoff_inbox&.conversations&.last
if handoff_conversation
  inbox = handoff_conversation.inbox
  inbox.define_singleton_method(:out_of_office?) { true }
  inbox.define_singleton_method(:out_of_office_message) { 'verify' }
  performed = false
  ooo.define_singleton_method(:new) { |**| Object.new.tap { |o| o.define_singleton_method(:perform) { performed = true } } }
  before = Message.count

  ooo.perform_if_applicable(handoff_conversation)
  check.call('custom handoff copy suppresses the out-of-office replay', false, performed)

  inbox.captain_assistant.config['handoff_message'] = ''
  ooo.perform_if_applicable(handoff_conversation)
  check.call('stock handoff copy still sends the out-of-office replay', true, performed)

  ooo.singleton_class.send(:remove_method, :new)
  check.call('no message created while checking', 0, Message.count - before)
end

puts failures.empty? ? "\nALL CHECKS PASSED" : "\n#{failures.length} FAILED:\n" + failures.join("\n")
exit(failures.empty? ? 0 : 1)
