# Product decisions

## Agreed

- Build a complete, lightweight Mac timer for personal use in the existing Xcode project. The menu bar is its primary interface.
- A scheduled break comes due every 20 minutes while the timer is running. The timer does not infer whether the user is looking at the screen or pause based on calls, idle input, or other activity.
- Provide an on-demand break from the menu bar.
- Completing any 20-second break, scheduled or on demand, resets the work interval to 20 minutes. Dismissing an on-demand break early restores the previous time remaining. An on-demand break started while manually paused returns to the paused state afterward.
- For a scheduled break, show a small animated countdown and then automatically open a 20-second break overlay. Offer a one-click **Snooze 5m** action and let **Escape** dismiss the overlay.
- **Snooze 5m** schedules the same break for five minutes from the click. **Escape** skips a scheduled break and starts a fresh 20-minute interval.
- Provide a manual **Pause / Resume** control in the menu bar. Pausing preserves the remaining work time. Sleep and lock suspend the work or snooze countdown. On waking or unlocking, resume it and replay the final warning if the countdown had already entered that phase. If the screen becomes unavailable during an active break, clear the overlay and begin a new work interval when the screen is usable again. Quitting stops the timer, and relaunch starts a fresh interval.
- Use animated, in-app cues for reminders. System notification banners, stats, phone or tablet mirroring, and Smart Pause are outside the scope.
- Use LookAway as a reference for timing and motion. The animations and interactions around a break are part of the finished app.

## Motion and presentation

- Show a brief, non-activating heads-up with snooze one minute before the break. For the final five seconds, show a small countdown alongside the pointer. Keep the countdown clear of the pointer hotspot and clamp it to the current display. **Take Break Now** opens the break directly.
- Fade into an original, slowly shifting gradient. Reveal the instruction to look about 20 feet away and the large countdown in stages. Fade back when the break ends and offer an optional completion chime.
- Dim each connected display during a break. Show the countdown and controls on the display with the pointer when the break starts. If that display goes away, move the controls to a remaining display and keep the same deadline.
- Respect Reduce Motion. Use a fixed-position warning, a still background, and a simple fade. Give controls accessible names and make them keyboard-operable. Announce break start and end for VoiceOver.
- Keep the animations tied to the timer. Use surfaces rendered by the app so the experience requires no screen recording or input monitoring permission. Separate blink and posture reminders and effects that capture the live desktop are outside scope.

## Verify on the Mac

- A heads-up leaves the active app and its text caret in place. Ending or dismissing a break returns keyboard focus to the previous app.
- Sleep and lock clear any visible warning or overlay. When the Mac is usable again, the timer reconciles once and gives a fresh final warning before showing an imminent break. Check ordinary lock, display sleep, and machine sleep separately.
- Fullscreen Spaces and multiple displays behave predictably. Connecting or disconnecting a display during a break neither restarts the countdown nor leaves a stray overlay.
- Pause, snooze, Escape, and Take Break Now produce one timer transition even when clicked near a deadline. Animation runs only during a visible cue or break.
