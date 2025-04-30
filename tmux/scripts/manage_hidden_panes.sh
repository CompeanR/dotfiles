#!/usr/bin/env bash

# Script to manage hiding and restoring tmux panes

# --- Configuration ---
# The name of the window where hidden panes will be stored
HIDDEN_WINDOW_NAME="HiddenPanes"
# The tmux option used to store the list of hidden panes (pane_id:original_window_id)
HIDDEN_PANES_OPTION="@hidden_panes_list"

# --- Helper Functions ---

# Display a message in the tmux status line
display_message() {
    tmux display-message "HiddenPanes: $1"
}

# Get the ID of the HiddenPanes window, creating it if it doesn't exist
get_or_create_hidden_window_id() {
    local hidden_window_id
    # Try to find the existing window ID
    hidden_window_id=$(tmux list-windows -F '#{window_id}:#{window_name}' 2>/dev/null | grep -E "^[^:]+:${HIDDEN_WINDOW_NAME}$" | cut -d: -f1)

    if [ -z "$hidden_window_id" ]; then
        # Window doesn't exist, create it detached and get its ID
        hidden_window_id=$(tmux new-window -d -n "$HIDDEN_WINDOW_NAME" -P -F '#{window_id}' 2>/dev/null)
        if [ -z "$hidden_window_id" ]; then
             display_message "Error: Could not create '$HIDDEN_WINDOW_NAME' window."
             exit 1
        fi
        display_message "Created '$HIDDEN_WINDOW_NAME' window."
    fi
    echo "$hidden_window_id"
}

# --- Core Functions ---

hide_pane() {
    # Get current pane and window info
    local current_pane_id current_window_id current_window_name pane_count
    current_pane_id="$1"
    current_window_id=$(tmux display-message -p '#{window_id}')
    current_window_name=$(tmux display-message -p '#{window_name}')
    pane_count=$(tmux list-panes -t "$current_window_id" | wc -l)

    # Prevent hiding from the HiddenPanes window itself
    if [ "$current_window_name" = "$HIDDEN_WINDOW_NAME" ]; then
        display_message "Error: Cannot hide panes from the '$HIDDEN_WINDOW_NAME' window."
        exit 1
    fi

    # Prevent hiding the last pane in a window (would destroy the window)
    if [ "$pane_count" -le 1 ]; then
        display_message "Error: Cannot hide the last pane in a window."
        exit 1
    fi

    # Get the target window ID for hidden panes
    local hidden_window_id
    hidden_window_id=$(get_or_create_hidden_window_id)
    if [ -z "$hidden_window_id" ]; then
        # Error message already shown by get_or_create_hidden_window_id
        exit 1
    fi

    # Get the current list of hidden panes
    local hidden_panes_list current_entry
    hidden_panes_list=$(tmux show-options -gqv "$HIDDEN_PANES_OPTION")

    # Prepare the entry for the pane being hidden (pane_id:original_window_id)
    current_entry="${current_pane_id}:${current_window_id}"

    # Add the current pane to the *beginning* of the list (LIFO)
    tmux set-option -g "$HIDDEN_PANES_OPTION" "$current_entry $hidden_panes_list"

    # Move the pane. This command, by default, does NOT switch focus
    # away from the original window when moving to a different window.
    if tmux join-pane -d -s "$current_pane_id" -t "$hidden_window_id"; then
        display_message "Pane $current_pane_id hidden. Use Prefix+O to restore."
    else
        display_message "Error: Failed to move pane $current_pane_id."
        # Rollback: Remove the entry we added if the move failed
        local updated_list
        updated_list=$(echo "$hidden_panes_list" | sed "s/^${current_entry} //; s/ ${current_entry}//; s/^${current_entry}$//")
        tmux set-option -g "$HIDDEN_PANES_OPTION" "$updated_list"
        exit 1
    fi
}

restore_last() {
    # Get the list of hidden panes
    local hidden_panes_list
    hidden_panes_list=$(tmux show-options -gqv "$HIDDEN_PANES_OPTION")

    # Check if there are any panes to restore
    if [ -z "$hidden_panes_list" ]; then
        display_message "No panes to restore."
        exit 0
    fi

    # Get the details of the *last* hidden pane (first in the list)
    local last_hidden_entry pane_to_restore_id original_window_id remaining_list
    # Use awk to reliably get the first field (entry)
    last_hidden_entry=$(echo "$hidden_panes_list" | awk '{print $1}')
    pane_to_restore_id=$(echo "$last_hidden_entry" | cut -d: -f1)
    # original_window_id=$(echo "$last_hidden_entry" | cut -d: -f2) # We restore to current window now

    # Get the current window ID where the user wants to restore the pane
    local target_window_id
    target_window_id=$(tmux display-message -p '#{window_id}')
    # Optional: could restore to original_window_id if desired: target_window_id=$original_window_id

    # Get the ID of the HiddenPanes window (it must exist if we have hidden panes listed)
    local hidden_window_id
    hidden_window_id=$(tmux list-windows -F '#{window_id}:#{window_name}' 2>/dev/null | grep -E "^[^:]+:${HIDDEN_WINDOW_NAME}$" | cut -d: -f1)

    if [ -z "$hidden_window_id" ]; then
         display_message "Error: '$HIDDEN_WINDOW_NAME' window not found, but panes are listed!"
         # Maybe clear the list as it's inconsistent?
         # tmux set-option -gu "$HIDDEN_PANES_OPTION"
         exit 1
    fi

    # Check if the pane ID actually exists in the hidden window (sanity check)
    if ! tmux list-panes -t "$hidden_window_id" -F '#{pane_id}' | grep -q "^${pane_to_restore_id}$"; then
        display_message "Error: Pane $pane_to_restore_id not found in '$HIDDEN_WINDOW_NAME'. Stale data?"
        # Remove the stale entry from the list
        remaining_list=$(echo "$hidden_panes_list" | awk '{$1=""; print $0}' | sed 's/^ *//') # Remove first element safely
        tmux set-option -g "$HIDDEN_PANES_OPTION" "$remaining_list"
        exit 1
    fi

    # Move the pane back to the target window. It will be added as a new pane.
    if tmux move-pane -s "$pane_to_restore_id" -t "$target_window_id"; then
        # Select the newly restored pane
        tmux select-pane -t "$pane_to_restore_id"
        display_message "Pane $pane_to_restore_id restored."

        # Remove the restored pane's entry from the list
        remaining_list=$(echo "$hidden_panes_list" | awk '{$1=""; print $0}' | sed 's/^ *//') # Remove first element safely
        tmux set-option -g "$HIDDEN_PANES_OPTION" "$remaining_list"

        # Check if the HiddenPanes window is now empty and kill it if so
        local pane_count_in_hidden
        # Add a small delay in case tmux needs a moment to update internal state after move-pane
        sleep 0.1
        pane_count_in_hidden=$(tmux list-panes -t "$hidden_window_id" 2>/dev/null | wc -l)

        if [ "$pane_count_in_hidden" -eq 0 ]; then
            tmux kill-window -t "$hidden_window_id"
        fi
    else
        display_message "Error: Failed to restore pane $pane_to_restore_id."
        exit 1
    fi
}

restore_id() {
    local target_id="$1"
    
    # Debug: Display the target ID being requested
    display_message "Attempting to restore pane: $target_id"
    
    # Get the list of hidden panes
    local hidden_panes_list
    hidden_panes_list=$(tmux show-options -gqv "$HIDDEN_PANES_OPTION")

    # Check if there are any panes to restore
    if [ -z "$hidden_panes_list" ]; then
        display_message "No panes to restore."
        exit 0
    fi

    # Find the pane with the given ID in the list
    local matching_entry="" remaining_list=""
    for entry in $hidden_panes_list; do
        pane_id=$(echo "$entry" | cut -d: -f1)
        if [ "$pane_id" = "$target_id" ]; then
            matching_entry="$entry"
        else
            remaining_list="$remaining_list $entry"
        fi
    done
    
    # Trim leading space
    remaining_list=$(echo "$remaining_list" | sed 's/^ *//')
    
    if [ -z "$matching_entry" ]; then
        display_message "Error: Pane $target_id not found in hidden panes list."
        # List all available pane IDs for debugging
        local available_ids=""
        for entry in $hidden_panes_list; do
            available_ids="$available_ids $(echo "$entry" | cut -d: -f1)"
        done
        display_message "Available panes: $available_ids"
        exit 1
    fi

    # Get the ID of the HiddenPanes window
    local hidden_window_id
    hidden_window_id=$(tmux list-windows -F '#{window_id}:#{window_name}' 2>/dev/null | grep -E "^[^:]+:${HIDDEN_WINDOW_NAME}$" | cut -d: -f1)

    if [ -z "$hidden_window_id" ]; then
         display_message "Error: '$HIDDEN_WINDOW_NAME' window not found!"
         exit 1
    fi

    # Verify the pane exists in the hidden window
    if ! tmux list-panes -t "$hidden_window_id" -F '#{pane_id}' | grep -q "^${target_id}$"; then
        display_message "Error: Pane $target_id not found in '$HIDDEN_WINDOW_NAME' window."
        # List all visible panes in the hidden window
        local visible_panes=$(tmux list-panes -t "$hidden_window_id" -F '#{pane_id}')
        display_message "Visible panes in $HIDDEN_WINDOW_NAME: $visible_panes"
        exit 1
    fi

    # Get the current window ID where the user wants to restore the pane
    local target_window_id
    target_window_id=$(tmux display-message -p '#{window_id}')

    # Move the pane back to the target window
    if tmux move-pane -s "$target_id" -t "$target_window_id"; then
        # Select the newly restored pane
        tmux select-pane -t "$target_id"
        display_message "Pane $target_id restored successfully."

        # Update the list of hidden panes
        tmux set-option -g "$HIDDEN_PANES_OPTION" "$remaining_list"

        # Check if the HiddenPanes window is now empty and kill it if so
        local pane_count_in_hidden
        sleep 0.1
        pane_count_in_hidden=$(tmux list-panes -t "$hidden_window_id" 2>/dev/null | wc -l)

        if [ "$pane_count_in_hidden" -eq 0 ]; then
            tmux kill-window -t "$hidden_window_id"
        fi
    else
        display_message "Error: Failed to restore pane $target_id."
        exit 1
    fi
}

list_panes() {
    # Get the list of hidden panes
    local hidden_panes_list
    hidden_panes_list=$(tmux show-options -gqv "$HIDDEN_PANES_OPTION")

    # Check if there are any panes to list
    if [ -z "$hidden_panes_list" ]; then
        display_message "No hidden panes available."
        exit 0
    fi

    # Build an array of pane IDs for selection
    declare -a pane_ids
    local count=0
    for entry in $hidden_panes_list; do
        count=$((count + 1))
        pane_id=$(echo "$entry" | cut -d: -f1)
        pane_ids[$count]="$pane_id"
    done

    # Create a menu with options to select and restore panes
    local menu_options=""
    for i in $(seq 1 $count); do
        # Add each pane as a selectable menu item
        menu_options+="\"Restore Pane #$i\" $i \"run-shell \\\"$0 restore_id ${pane_ids[$i]}\\\"\" "
    done

    # Display the menu
    eval "tmux display-menu -T \"Hidden Panes\" $menu_options"
}

clear_all() {
    # Get the ID of the HiddenPanes window
    local hidden_window_id
    hidden_window_id=$(tmux list-windows -F '#{window_id}:#{window_name}' 2>/dev/null | grep -E "^[^:]+:${HIDDEN_WINDOW_NAME}$" | cut -d: -f1)

    # Clear the list of hidden panes
    tmux set-option -g "$HIDDEN_PANES_OPTION" ""

    # Kill the HiddenPanes window if it exists
    if [ -n "$hidden_window_id" ]; then
        tmux kill-window -t "$hidden_window_id" 2>/dev/null
    fi

    display_message "All hidden panes cleared."
}

jump() {
    # Get the ID of the HiddenPanes window
    local hidden_window_id
    hidden_window_id=$(tmux list-windows -F '#{window_id}:#{window_name}' 2>/dev/null | grep -E "^[^:]+:${HIDDEN_WINDOW_NAME}$" | cut -d: -f1)

    if [ -z "$hidden_window_id" ]; then
        display_message "Error: '$HIDDEN_WINDOW_NAME' window not found!"
        exit 1
    fi

    # Jump to the HiddenPanes window
    tmux select-window -t "$hidden_window_id"
}

# --- Main Logic ---

# Check if running inside tmux
if [ -z "$TMUX" ]; then
    echo "Error: This script must be run inside a tmux session." >&2
    exit 1
fi

# Parse command-line arguments
case "$1" in
    hide)
        hide_pane "$2"
        ;;
    restore_last)
        restore_last
        ;;
    restore_id)
        restore_id "$2"
        ;;
    list)
        list_panes
        ;;
    clear)
        clear_all
        ;;
    jump)
        jump
        ;;
    *)
        echo "Usage: $0 {hide|restore_last|restore_id|list|clear|jump} [args...]" >&2
        exit 1
        ;;
esac

exit 0