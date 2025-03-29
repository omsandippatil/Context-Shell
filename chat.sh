#!/bin/bash

# Context-Aware Chatbot using Groq API
# Author: Improved version
# Date: March 29, 2025

# Configuration
GROQ_API_KEY="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"
CONTEXT_FILE="context.json"
MODEL="llama3-70b-8192"
DATE=$(date +"%Y-%m-%d")
MAX_CONVERSATION_HISTORY=20

# Ensure required tools are available
for cmd in curl jq; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is required but not installed. Please install it and try again."
        exit 1
    fi
done

# Initialize context file if it doesn't exist
initialize_context() {
    if [ ! -f "$CONTEXT_FILE" ]; then
        echo '{
            "facts": [],
            "dates": {},
            "conversations": []
        }' | jq '.' > "$CONTEXT_FILE"
        echo "Created new context file: $CONTEXT_FILE"
    fi
}

# Escape strings for JSON
escape_json() {
    echo "$1" | jq -Rs '.'
}

# Call Groq API
call_groq() {
    local prompt="$1"
    local system_message="$2"
    local max_retries=3
    local retry_count=0
    local response=""
    
    # Create JSON payload
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$system_message" \
        --arg user "$prompt" \
        '{
            "model": $model,
            "temperature": 0.7,
            "messages": [
                {"role": "system", "content": $system},
                {"role": "user", "content": $user}
            ]
        }')

    # Try API call with retries
    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
            -H "Authorization: Bearer $GROQ_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload")
        
        # Check if we got a valid response
        if echo "$response" | jq -e '.choices[0].message.content' &>/dev/null; then
            # Extract just the content from the response
            echo "$response" | jq -r '.choices[0].message.content'
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "API call failed (attempt $retry_count/$max_retries). Retrying..." >&2
            sleep 1
        fi
    done
    
    echo "Error: Failed to get response after $max_retries attempts"
    return 1
}

# Extract facts and dates
extract_facts_and_dates() {
    local text="$1"
    
    # Build a system prompt with example JSON format
    local system_prompt="Extract the 3-5 most important facts from this text, with special attention to dates. 
    
Format your response STRICTLY as a valid JSON with two fields: 
- 'facts' (array of strings) 
- 'dates' (object mapping descriptions to date strings)

EXAMPLE OUTPUT FORMAT:
{
  \"facts\": [
    \"The meeting was rescheduled to next week\",
    \"Project Alpha needs to be completed by end of quarter\",
    \"Sarah will lead the marketing team\"
  ],
  \"dates\": {
    \"Meeting rescheduled\": \"2025-04-05\",
    \"Project Alpha deadline\": \"2025-06-30\"
  }
}

IMPORTANT: Output ONLY the JSON with no additional text, explanation, or formatting."
    
    # Call Groq for extraction
    local extraction=$(call_groq "$text" "$system_prompt")
    
    # Ensure we have valid JSON output
    if echo "$extraction" | jq empty &>/dev/null; then
        echo "$extraction"
    else
        # Try to fix common JSON parsing issues
        local fixed_json=$(echo "$extraction" | sed 's/```json//g' | sed 's/```//g' | sed 's/^```$//g')
        if echo "$fixed_json" | jq empty &>/dev/null; then
            echo "$fixed_json"
        else
            echo "Warning: Received invalid JSON from extraction process" >&2
            echo '{"facts":[],"dates":{}}'
        fi
    fi
}

# Update context safely
update_context() {
    local user_input="$1"
    local bot_response="$2"
    local extraction="$3"
    
    # Create backup of current context
    cp "$CONTEXT_FILE" "${CONTEXT_FILE}.bak"
    
    # Prepare the conversation entry
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Validate extraction JSON
    if ! echo "$extraction" | jq empty &>/dev/null; then
        echo "Warning: Received invalid JSON from extraction process" >&2
        extraction='{"facts":[],"dates":{}}'
    fi
    
    # Update context in a safe way
    jq --argjson extraction "$extraction" \
       --arg timestamp "$timestamp" \
       --arg user "$user_input" \
       --arg assistant "$bot_response" \
       --argjson max_history "$MAX_CONVERSATION_HISTORY" \
    '
        # Add new facts
        .facts = (.facts + $extraction.facts | unique) |
        
        # Add new dates
        .dates = (.dates + $extraction.dates) |
        
        # Add conversation and limit history
        .conversations = (.conversations + [{
            "timestamp": $timestamp,
            "user": $user,
            "assistant": $assistant
        }] | if length > $max_history then .[-$max_history:] else . end)
    ' "${CONTEXT_FILE}.bak" > "$CONTEXT_FILE"
    
    # Check if operation was successful
    if [ $? -eq 0 ] && [ -s "$CONTEXT_FILE" ]; then
        # Validate the new context file
        if jq empty "$CONTEXT_FILE" &>/dev/null; then
            echo "Context updated successfully."
            rm "${CONTEXT_FILE}.bak"
        else
            echo "Error: Generated invalid JSON. Restoring backup." >&2
            mv "${CONTEXT_FILE}.bak" "$CONTEXT_FILE"
        fi
    else
        echo "Error: Failed to update context file. Restoring backup." >&2
        mv "${CONTEXT_FILE}.bak" "$CONTEXT_FILE"
    fi
}

# Display help
show_help() {
    cat << EOF
Available commands:
  !context   - Show current context summary
  !facts     - Show only stored facts
  !dates     - Show only stored dates
  !history N - Show last N conversations (default: 5)
  !reset     - Reset context to empty state
  !save FILE - Save context to specified file
  !load FILE - Load context from specified file
  !help      - Show this help message
  exit       - Exit the chatbot
EOF
}

# Show history
show_history() {
    local count=${1:-5}
    jq --argjson count "$count" '.conversations[-$count:] | .[] | "[\(.timestamp)]\nYou: \(.user)\nBot: \(.assistant)\n"' -r "$CONTEXT_FILE"
}

# Show facts
show_facts() {
    jq -r '.facts | map("• " + .) | join("\n")' "$CONTEXT_FILE" || echo "No facts stored yet."
}

# Show dates
show_dates() {
    jq -r '.dates | to_entries | map("• " + .key + ": " + .value) | join("\n")' "$CONTEXT_FILE" || echo "No dates stored yet."
}

# Save context to file
save_context() {
    local target_file="$1"
    if [ -z "$target_file" ]; then
        target_file="context_$(date +%Y%m%d_%H%M%S).json"
    fi
    cp "$CONTEXT_FILE" "$target_file" && echo "Context saved to $target_file"
}

# Load context from file
load_context() {
    local source_file="$1"
    if [ -f "$source_file" ] && jq empty "$source_file" &>/dev/null; then
        cp "$source_file" "$CONTEXT_FILE" && echo "Context loaded from $source_file"
    else
        echo "Error: Invalid context file or file not found."
    fi
}

# Main function
main() {
    # Initialize context
    initialize_context
    
    # Welcome message
    echo "Context-Aware Chatbot (type 'exit' to quit, '!help' for commands)"
    echo "--------------------------------------"
    echo "Today's date: $DATE"
    echo "Model: $MODEL"
    echo "--------------------------------------"
    
    # Main chat loop
    while true; do
        # Get user input
        echo -n "You: "
        read -r user_input
        
        # Check for commands
        case "$user_input" in
            exit)
                echo "Goodbye! Your conversation context has been saved."
                exit 0
                ;;
            !context)
                echo "Current context summary:"
                jq '.' "$CONTEXT_FILE"
                echo "--------------------------------------"
                continue
                ;;
            !facts)
                echo "Stored facts:"
                show_facts
                echo "--------------------------------------"
                continue
                ;;
            !dates)
                echo "Stored dates:"
                show_dates
                echo "--------------------------------------"
                continue
                ;;
            !history*)
                echo "Conversation history:"
                count=$(echo "$user_input" | sed 's/!history //' | grep -o '[0-9]*')
                show_history "${count:-5}"
                echo "--------------------------------------"
                continue
                ;;
            !reset)
                echo '{
                    "facts": [],
                    "dates": {},
                    "conversations": []
                }' | jq '.' > "$CONTEXT_FILE"
                echo "Context has been reset."
                echo "--------------------------------------"
                continue
                ;;
            !save*)
                file=$(echo "$user_input" | sed 's/!save //')
                save_context "$file"
                echo "--------------------------------------"
                continue
                ;;
            !load*)
                file=$(echo "$user_input" | sed 's/!load //')
                load_context "$file"
                echo "--------------------------------------"
                continue
                ;;
            !help)
                show_help
                echo "--------------------------------------"
                continue
                ;;
            "")
                # Skip empty input
                continue
                ;;
        esac
        
        # Extract facts and dates as formatted strings for the system message
        facts_str=$(show_facts)
        dates_str=$(show_dates)
        
        # Create system message
        system_message="You are a helpful assistant with memory. Today's date is $DATE. 

Previously known facts:
$facts_str

Important dates:
$dates_str

Use this information in your responses when relevant."
        
        # Get response from Groq
        echo "Thinking..."
        bot_response=$(call_groq "$user_input" "$system_message")
        
        # Check if we got a valid response
        if [ -z "$bot_response" ] || [ "$bot_response" = "Error: Failed to get response after 3 attempts" ]; then
            echo "Bot: Sorry, I encountered an error while processing your request. Please try again."
            continue
        fi
        
        # Display response
        echo "Bot: $bot_response"
        
        # Extract facts and dates from the conversation
        echo "Updating memory..."
        extraction=$(extract_facts_and_dates "$user_input $bot_response")
        
        # Update context with new information
        update_context "$user_input" "$bot_response" "$extraction"
        
        echo "--------------------------------------"
    done
}

# Run the main function
main