# Make the IMAP email inbox honor Inbox#lock_to_single_conversation.
# Upstream (v4.17.1) checks the flag in ConversationBuilder and the WhatsApp/SMS/
# Facebook services, but Imap::ImapMailbox#find_or_create_conversation calls
# Conversation.create! directly, so email threads only when the sender's client
# sends In-Reply-To/References. Contacts that compose a fresh mail each time get
# a new conversation per message, and Captain answers each with no history.
Rails.application.config.to_prepare do
  Imap::ImapMailbox.prepend(Module.new do
    def find_or_create_conversation
      existing = @contact_inbox.conversations.last if @inbox.lock_to_single_conversation?
      existing ? (@conversation = existing) : super
    end
  end)
end
