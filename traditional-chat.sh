#!/bin/bash

# Configuration
GROQ_API_KEY="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"
CONTEXT_FILE="context.txt"
MODEL="llama3-70b-8192"

# Initialize context file if it doesn't exist
if [ ! -f "$CONTEXT_FILE" ]; then
    touch "$CONTEXT_FILE"
    echo "# Context File - Conversation History and Key Facts" > "$CONTEXT_FILE"
    echo "# Format: [User Input] [Bot Response] [Extracted Facts]" >> "$CONTEXT_FILE"
    echo "--------------------------------------" >> "$CONTEXT_FILE"
fi

# Function to call Groq API
call_groq() {
    local prompt="$1"
    local system_message="$2"
    
    # Create JSON payload
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$prompt" \
        --arg system "$system_message" \
        '{
            model: $model,
            messages: [
                {
                    role: "system",
                    content: $system
                },
                {
                    role: "user",
                    content: $prompt
                }
            ],
            temperature: 0.7
        }')
    
    # Make API call
    curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq -r '.choices[0].message.content'
}

# Function to extract facts from text
extract_facts() {
    local text="$1"
    
    # Ask Groq to extract key facts
    local fact_prompt="Analyze the following text and extract the most important factual information that should be remembered for future context. Return only the key facts in bullet point format:\n\n$text"
    
    local facts=$(call_groq "$fact_prompt" "You are an information extraction assistant. Identify and return only the most important factual information from the provided text.")
    
    echo "$facts"
}

# Function to update context
update_context() {
    local facts="$1"
    
    # Add timestamp and new facts to context file
    echo -e "\n[$(date)]" >> "$CONTEXT_FILE"
    echo -e "User Input: $user_input" >> "$CONTEXT_FILE"
    echo -e "Bot Response: $response" >> "$CONTEXT_FILE"
    echo -e "Extracted Facts:" >> "$CONTEXT_FILE"
    echo -e "$facts" >> "$CONTEXT_FILE"
    echo "--------------------------------------" >> "$CONTEXT_FILE"
}

# Main chat loop
echo "Terminal Chatbot Demo (type 'exit' to quit)"
echo "--------------------------------------"
echo "Context will be stored in $CONTEXT_FILE"
echo "--------------------------------------"

while true; do
    # Get user input
    echo -n "You: "
    read user_input

    # Check for exit command
    if [ "$user_input" = "exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    # Read current context
    current_context=$(cat "$CONTEXT_FILE")

    # Prepare prompt with context
    full_prompt="Current conversation context:\n$current_context\n\nNew user query: $user_input\n\nPlease respond to the user's query using the context if relevant. After your response, include a section with key facts to remember from this exchange."

    # Get response from Groq
    system_message="You are a helpful assistant. Respond to the user's query using the provided context if relevant. After your response, identify and list the key facts that should be remembered from this exchange."
    response=$(call_groq "$full_prompt" "$system_message")

    # Display response
    echo -e "Bot: $response"

    # Extract and store facts
    facts=$(extract_facts "$user_input\n\n$response")
    update_context "$facts"
    
    echo "--------------------------------------"
done