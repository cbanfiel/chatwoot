# Per-channel Captain handoff copy.
# Upstream stores a single handoff_message per assistant, so a live-chat visitor gets
# the email-shaped text ("they'll reply right here, and you'll get an email too").
# WebWidget conversations use config['handoff_message_chat'] when it is set; every
# other channel falls through to upstream behaviour.
# Call sites patched: enterprise/app/jobs/captain/conversation/response_builder_job.rb
# and enterprise/app/jobs/captain/inbox_pending_conversations_resolution_job.rb.
module ChannelAwareHandoffMessage
  def self.for(assistant, conversation)
    return if assistant.blank? || conversation.blank? || !conversation.inbox.web_widget?

    assistant.config['handoff_message_chat'].presence
  end
end

Rails.application.config.to_prepare do
  Captain::Conversation::ResponseBuilderJob.prepend(Module.new do
    private

    def create_handoff_message(preserve_waiting_since: false)
      content = ChannelAwareHandoffMessage.for(@assistant, @conversation)
      return super unless content

      @handoff_message = create_outgoing_message(content, preserve_waiting_since: preserve_waiting_since)
    end
  end)

  Captain::InboxPendingConversationsResolutionJob.prepend(Module.new do
    private

    def create_handoff_message(conversation)
      content = ChannelAwareHandoffMessage.for(captain_assistant, conversation)
      return super unless content

      conversation.messages.create!(
        message_type: :outgoing,
        sender: captain_assistant,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        content: content,
        preserve_waiting_since: true
      )
    end
  end)
end
