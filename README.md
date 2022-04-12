# Conversant

A text editor for the terminal.

The editor is built on top of an internal terminal library that is entirely agnostic to the editor so it can be used as a general purpose terminal library as well.

![image](https://user-images.githubusercontent.com/35064754/163024386-ecae45d0-0804-4b51-9b0f-2b752bc78e74.png)

# Features

Although this editor is abandoned and rather incomplete, here is some of what it can do:

* Supports UTF-8, LF-terminated files
* Modern cursor movement: a lot of modern keys and key combinations for cursor movement are implemented.
* The background color changes depending on the time and day
* Linux-only
* It is able to load the following files:
  https://raw.githubusercontent.com/KhronosGroup/Vulkan-Hpp/master/vulkan/vulkan_structs.hpp, https://raw.githubusercontent.com/dotnet/runtime/main/src/coreclr/gc/gc.cpp, https://github.com/microsoft/TypeScript/blob/main/src/compiler/checker.ts, and https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java
  (I needed an excuse to share this list of ridiculously huge files I found)
* Intuitive
* Can save
* Automatically reloads the currently edited file if it was edited externally
* It has a lot of tests that emulate key inputs to the editor
