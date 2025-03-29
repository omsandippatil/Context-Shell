#!/bin/bash

# Configuration
CONTEXT_FILE="context.json"
TARGET_TIMESTAMP="2025-03-29 06:58:32"
GROQ_API_KEY="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"
MODEL="llama3-70b-8192"

# Check if context file exists
if [ ! -f "$CONTEXT_FILE" ]; then
    echo "Error: Context file '$CONTEXT_FILE' not found."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install it and try again."
    exit 1
fi

# Function to extract conversation data for the specific timestamp
extract_conversation_data() {
    # Find the conversation entry with the specific timestamp
    local conversation=$(jq --arg ts "$TARGET_TIMESTAMP" '.conversations[] | select(.timestamp==$ts)' "$CONTEXT_FILE")
    
    if [ -z "$conversation" ]; then
        echo "No conversation found with timestamp: $TARGET_TIMESTAMP"
        return 1
    fi
    
    # Get the user message and assistant response
    local user_message=$(echo "$conversation" | jq -r '.user')
    local assistant_response=$(echo "$conversation" | jq -r '.assistant')
    
    # Get facts and dates that existed at that time
    local all_facts=$(jq -r '.facts[]' "$CONTEXT_FILE")
    local all_dates=$(jq -r '.dates | to_entries[] | "\(.key): \(.value)"' "$CONTEXT_FILE")
    
    # Create context information
    cat << EOF
CONVERSATION AT $TARGET_TIMESTAMP:
User: $user_message
Assistant: $assistant_response

KNOWN FACTS:
$all_facts

IMPORTANT DATES:
$all_dates
EOF
}

# Function to answer a question based on the context
answer_question() {
    local question="$1"
    local context="$2"
    
    # Create a system prompt for the AI
    local system_prompt="You are a helpful assistant that ONLY answers questions based on the provided context information. If the answer cannot be found in the context, say 'I don't have that information in my context.' Do not make up information.

CONTEXT INFORMATION:
$context

IMPORTANT INSTRUCTIONS:
1. Only use information from the provided context to answer
2. If the question cannot be answered from the context, say 'I don't have that information in my context'
3. Do not use any external knowledge beyond what's in the context
4. Be concise and specific in your answers"

    # Call Groq API to get the answer
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$system_prompt" \
        --arg user "$question" \
        '{
            "model": $model,
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content": $system},
                {"role": "user", "content": $user}
            ]
        }')

    local response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    # Extract and return the content from the response
    echo "$response" | jq -r '.choices[0].message.content // "Error: Failed to get a response from the API"'
}

# Extract the context data
context_data=$(extract_conversation_data)

# Check if we successfully extracted the context data
if [ $? -ne 0 ]; then
    echo "$context_data"
    exit 1
fi

# Display information about the script
echo "Context Query Tool - Answering questions from context at $TARGET_TIMESTAMP"
echo "--------------------------------------"
echo "Context loaded. You can now ask questions about this conversation."
echo "Type 'exit' to quit."
echo "--------------------------------------"

# Main question-answering loop
while true; do
    # Get the question from the user
    echo -n "Your question: "
    read -r question
    
    # Check if the user wants to exit
    if [ "$question" = "exit" ]; then
        echo "Goodbye!"
        exit 0
    fi
    
    # Answer the question based on the context
    echo "Searching context..."
    answer=$(answer_question "$question" "$context_data")
    
    # Display the answer
    echo -e "\nAnswer: $answer"
    echo "--------------------------------------"
done