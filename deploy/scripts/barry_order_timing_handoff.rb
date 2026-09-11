# Barry: hand off every order question about timing (ship/arrival dates, ETAs,
# late or stuck orders) instead of restating tool output. Idempotent.
# Run: make run FILE=scripts/barry_order_timing_handoff.rb

RULE_MARKER = 'when the order will ship or arrive'.freeze

INSTRUCTION_RULE = <<~TXT.strip
  5. The customer asks when the order will ship or arrive, asks for a date or timeframe,
     asks why an order is delayed or stuck, or says an order is late, past its ship date,
     or still in production. Do not restate the order status. Hand off.
  6. The customer sounds frustrated, annoyed, disappointed, upset, or impatient, or
     repeats a concern you already answered. Do not apologize and continue. Hand off.
TXT

GUIDELINE = 'For order timing questions (when it ships or arrives, any date or timeframe, delayed, late, ' \
            'or stuck orders), do not restate the order status and do not repeat what the customer said. ' \
            'Call the handoff tool immediately.'.freeze

FRUSTRATION_GUARDRAIL = 'If the customer shows any frustration, annoyance, disappointment, or impatience, or repeats a ' \
                        'concern you already answered, you MUST transfer to a human immediately using the handoff ' \
                        'tool. Do not ask permission first.'.freeze

GUARDRAIL = 'If the customer asks when an order will ship or arrive, asks for a date or timeframe, asks why an ' \
            'order is delayed or stuck, or says an order is late, past its ship date, or still in production, ' \
            'you MUST transfer to a human immediately using the handoff tool. Do not restate the order status ' \
            'and do not ask permission first.'.freeze

a = Captain::Assistant.find(1)
raise "expected Barry, got #{a.name}" unless a.name == 'Barry'

config = a.config.deep_dup
unless config['instructions'].include?(RULE_MARKER)
  config['instructions'] = config['instructions'].sub(
    /(4\. The customer asks for a price quote[^\n]*\n)/,
    "\\1#{INSTRUCTION_RULE}\n"
  )
  raise 'instruction anchor not found' unless config['instructions'].include?(RULE_MARKER)
end
config['instructions'] = config['instructions'].sub(
  '- The customer asks about order status or tracking - use the order status tool.',
  '- The customer asks for current order status or a tracking number - use the order status tool. Timing questions hand off (rule 5).'
)
config['handoff_message_chat'] = "I've made a ticket for this. A teammate will reply via email within 24-48 hours."

guidelines = a.response_guidelines.dup
guidelines << GUIDELINE unless guidelines.include?(GUIDELINE)

guardrails = a.guardrails.dup
guardrails << GUARDRAIL unless guardrails.include?(GUARDRAIL)
guardrails << FRUSTRATION_GUARDRAIL unless guardrails.include?(FRUSTRATION_GUARDRAIL)

a.update!(config: config, response_guidelines: guidelines, guardrails: guardrails)
a.reload
puts '=== INSTRUCTIONS'; puts a.config['instructions']
puts '=== GUIDELINES'; a.response_guidelines.each_with_index { |g, i| puts "#{i}: #{g}" }
puts '=== GUARDRAILS'; a.guardrails.each_with_index { |g, i| puts "#{i}: #{g}" }
puts '=== HANDOFF CHAT'; puts a.config['handoff_message_chat']
