# No out-of-office replay on Captain handoff when the assistant has its own handoff copy.
# Upstream: app/services/message_templates/template/out_of_office.rb
#   MessageTemplates::Template::OutOfOffice.perform_if_applicable
# It is called only from the Captain handoff paths (Captain::Tools::HandoffTool,
# ResponseBuilderJob v1 handoff, the usage-limit handoff in
# Enterprise::MessageTemplates::HookExecutionService and InboxPendingConversationsResolutionJob)
# so an after-hours customer learns humans are offline. The stock handoff copy says nothing
# about timing, so that made sense. Our copy already promises a reply window, so the customer
# got two auto-replies back to back. Stock copy keeps upstream behaviour.
Rails.application.config.to_prepare do
  MessageTemplates::Template::OutOfOffice.singleton_class.prepend(Module.new do
    def perform_if_applicable(conversation)
      assistant = conversation.inbox.captain_assistant
      custom_copy = ChannelAwareHandoffMessage.for(assistant, conversation) ||
                    assistant&.config&.dig('handoff_message').presence
      return if custom_copy

      super
    end
  end)
end
