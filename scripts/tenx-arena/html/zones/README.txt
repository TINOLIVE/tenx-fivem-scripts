Zone pictures go here.

Drop a PNG or JPG in this folder and point at it from Config.RedZone.images,
keyed by the arena's name:

    images = {
        ['Docks']    = 'zones/docks.png',
        ['Rooftops'] = 'zones/rooftops.png',
    },

Anything landscape works; the card crops to 16:9. Around 640x360 is plenty --
it renders small, and a large file is loaded by every player who opens the menu.

A zone without a picture gets a generated one: a colour derived from its name,
so it still looks like itself rather than an empty box.
