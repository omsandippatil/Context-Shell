#!/bin/bash

# Configuration
CONTEXT_FILE="context.txt"
MODEL="llama3-70b-8192"
GROQ_API_KEY="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"

# Function to search context file
search_context() {
    local query="$1"
    
    # Search for relevant sections in context
    local relevant_context=$(grep -i -A 10 -B 5 "$query" "$CONTEXT_FILE" | head -n 100)
    
    if [ -z "$relevant_context" ]; then
        echo "No matching context found for: $query"
        return 1
    else
        echo "$relevant_context"
    fi
}

# Function to answer from context
answer_from_context() {
    local query="$1"
    local context="$2"
    
    # Prepare prompt for Groq
    local prompt="Context information is below:
--------------------
$context
--------------------
Given the context information and not prior knowledge, answer the query.
Query: $query"

    # Call Groq API to formulate answer
    local answer=$(call_groq "$prompt" "You are a helpful assistant that answers questions based strictly on the provided context. If the answer isn't in the context, say 'I don't have that information in my context.'")
    
    echo "$answer"
}

# Function to call Groq API (same as before)
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
            temperature: 0.3  # Lower temperature for more factual answers
        }')
    
    # Make API call
    curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq -r '.choices[0].message.content'
}

# Main Q&A loop
echo "Context-Based Q&A System (type 'exit' to quit)"
echo "---------------------------------------------"
echo "I'll answer questions based on stored context in $CONTEXT_FILE"
echo "---------------------------------------------"

while true; do
    # Get user question
    echo -n "Your question: "
    read user_question

    # Check for exit command
    if [ "$user_question" = "exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    # Search context for relevant information
    echo "Searching context..."
    found_context=$(search_context "$user_question")
    
    if [ $? -eq 0 ]; then
        echo -e "\nFound relevant context:"
        echo "---------------------"
        echo "$found_context"
        echo "---------------------"
        
        # Generate answer from context
        echo -e "\nFormulating answer..."
        answer=$(answer_from_context "$user_question" "$found_context")
        echo -e "Answer: $answer"
    else
        echo "I couldn't find any relevant information in my context."
    fi
    
    echo "---------------------------------------------"
done