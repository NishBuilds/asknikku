# asknikku
a Linux CLI tool for asking local AI questions about shell errors/outputs. As you work in the terminal and encounter errors, you can in the terminal itself troubleshoot them or learn more about them.

modify the .sh file at the top to specify your local AI host IP and port, then run the installer

then refresh shell with exec bash 



Usage:
  asknikku "your prompt"
  asknikku -a "question about the last captured terminal output"
  asknikku -b "follow-up about the asknikku exchange history, anchored to the original terminal output when available"
  asknikku -model="MODELNAME" "your prompt"
  asknikku -a -model="MODELNAME" "question about the last captured output"

Flags:
  -a
      Use the most recently captured shell command and shell output as context.
      asknikku itself is always skipped by the shell hook, so -a always refers
      to the last proper terminal command/output.

  -b
      Use the last 6 asknikku exchanges as context.
      The newest prior exchange is marked as the one to focus on.
      The 5 older prior exchanges are marked as background memory/context.
      If the asknikku conversation started right after a real terminal command/output,
      that original terminal command/output is also included as an anchor.
      You cannot combine -a and -b in the same command.

  -model="MODELNAME"
      Override the default model just for this command.
      Example: asknikku -model="llama3.1:8b" "summarize this"

Examples:
  asknikku "tell me about Antarctica"
  asknikku -a "what does this error mean"
  asknikku -b "can you say more?"
  asknikku -b "what part of your last answer matters most?"
  asknikku -a -model="qwen2.5:14b" "what should I do next"

Control shell capture if a fullscreen app conflicts:
  asknikku-capture off
  asknikku-capture on
  asknikku-capture status

