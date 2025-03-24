#!/bin/bash

# Configuration
GROQ_API_KEY="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"
CONTEXT_FILE="context.txt"
MODEL="llama3-70b-8192"  

# Initialize context file if it doesn't exist
if [ ! -f "$CONTEXT_FILE" ]; then
    touch "$CONTEXT_FILE"
    echo "# Context File - Key Facts from Conversation" > "$CONTEXT_FILE"
fi

# Function to call Groq API
call_groq() {
    local prompt="$1"
    local system_message="$2"
    
    # Create JSON payload
    local payload=$(cat <<EOF
{
    "messages": [
        {
            "role": "system",
            "content": "$system_message"
        },
        {
            "role": "user",
            "content": "$prompt"
        }
    ],
    "model": "$MODEL"
}
EOF
)

    # Make API call
    response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    # Extract just the content from the response
    echo "$response" | grep -o '"content":"[^"]*"' | cut -d'"' -f4
}

# Function to extract key facts
extract_facts() {
    local text="$1"
    
    # Create system message for fact extraction
    local system_message="Extract the most important facts from the following text. Provide them as short, concise bullet points. Focus only on factual information, not opinions or explanations. Return at most 5 key points."
    
    # Call Groq for fact extraction
    call_groq "$text" "$system_message"
}

# Function to update context
update_context() {
    local new_facts="$1"
    local current_context=$(cat "$CONTEXT_FILE")
    
    # Create system message for context updating
    local system_message="You are a context manager. You will be given the current context (current facts) and new facts. Create an updated context by merging them, removing redundancies, and keeping only the most important information. The output should be a bullet point list of facts, each starting with '- '. Keep the total under 10 bullet points."
    
    # Prepare prompt with current context and new facts
    local prompt="Current context:\n$current_context\n\nNew facts to incorporate:\n$new_facts"
    
    # Call Groq for context updating
    local updated_context=$(call_groq "$prompt" "$system_message")
    
    # Save updated context
    echo "$updated_context" > "$CONTEXT_FILE"
}

# Main chat loop
echo "Terminal Chatbot (type 'exit' to quit)"
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
    full_prompt="Current context:\n$current_context\n\nUser query: $user_input\n\nPlease respond to the user's query using the context if relevant."
    
    # Get response from Groq
    system_message="You are a helpful assistant. Respond to the user's query using the provided context if relevant."
    response=$(call_groq "$full_prompt" "$system_message")
    
    # Display response
    echo -e "Bot: $response"
    
    # Extract key facts from the response
    facts=$(extract_facts "$response")
    
    # Update context with new facts
    update_context "$facts"
    
    echo "--------------------------------------"
done