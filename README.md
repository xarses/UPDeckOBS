# (Unofficial) UPDeck OBS Scrip =

This script is a unofficial fork of the OBS lua script that is used
with UPDeck to communicate between the UPDeck server process and OBS.

The last official version is kept on the `official` (2.1.21) branch and can likely still
be found on the UPDeck discord server.

# Fixes
* The command animate has a morph=targetItem parameter that is supposed to copy all of the parameters including its clip, which was not getting copied correctly. This should also fix the morph parameter that is also supported by position|resize|rotate|opacity
* `alpha` in `animate|position|resize|rotate|opacity` is fixed to convert 2-100 to a float between 0 and 1 (what OBS expects). If your weird and want to set your alpha to `1` as in 1% you need to convert it to a float by hand (`0.01`) as this will be interpreted as fully on

# Changes

Here are a list of the current changes offered by this fork.

## New commands

### swap
When in studio mode, it swaps the current preview scene with the program
screen.

**Params**
`trans`: (Optional) the transition to use if you don't want to use the default.


```
switch preview and program
swap
trans=some_optional_transition
```

### open_projector
Can open a projector window in a number of ways

**Params**

`type`: (Optional) One of `Preview` (default), `Source`, `Scene`, `StudioProgram` or `Multiveiw` (case insensitive). Describes what type of projector we want to open.

`monitor` (Optional) the monitor number to show the projector on. or `-1` (default) for a window

`name` (Optional) the name of the source or scene to be displayed (ignored for other projector types)

```
open a projector scene
type=scene
name=Game window
```

## Modified behaviors

### record
record has been extended to be able to pause/unpause the recording. (Note:
the ability to pause is dependent on your output settings and most specifically
the format your using (mkv supports this)). Toggling pause while not recording
will result in nothing occurring.

**Params**

(Positional) values: `start` `stop` `pause` (Anything else)

`start` will start the recording
`stop` will stop the current recording if you are recording
`pause` will toggle the current paused state if your recording was already started
(Anything else) Will toggle the stop/start state.

```
toggle recording
record

toggle pause
record
pause
```

### meta parameters for scene
Add `_preview` support for scene name meta, as well as unify all meta keywords
for the `scene` argument.

`_preview` will target the scene currently in the preview window when you are in
studio mode.

Any command that takes an argument of `scene` supports the following meta names:
* `_preview`
* `_previous`
* `_current`

There is also `_all` which can only be used with the `show` command

This also allows `_previous` to be used where a `scene` name may be passed.
However this **ONLY** works if you have used the `switch` command as its the
only command that sets the value for `_previous`

You can also now use `switch` to swap between the Preview and program as well
as the command `swap`

```
Load preview to program
switch
scene=_preview
```

### Repair OBS -> UpDeck buttons 
In prior versions, there was a feature that allowed the user to bind a
keycode in OBS that would send to UP Deck to be read and executed.

This was broken due to a change that introduced decks, previously it
looked like buttons where individual files inside of a single deck.

We repaired this by piggy-backing on a not-intended interface to send
the command back to the UPDeck Server. This results in a less than
ideal delay of up to 8 seconds (the update interval in the client).

The delay is due to the fact that this buffer will only be read if a
command is sent by the actual client as there is no direct pulling for
this queue. Fortunately the client sends a update to read any of the
volumes (configured or not) every 8 seconds.

To use this, you need a) have a deck saved on the server b) you need
to set this deck name in the OBS Script settings

