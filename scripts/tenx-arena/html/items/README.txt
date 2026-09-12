Pictures for items that only exist in this script.

The match inventory is our own storage -- our own slots, our own
database table. It does NOT use ox_inventory, so you do not need to add any of
these to ox_inventory/data/items.lua for them to work.

The only thing ox is used for is images: anything not in this folder is looked
up in ox_inventory/web/images. That means weapons, medkits and armour look
exactly like they do in the city without duplicating anything.

Most items do NOT belong here. Weapons, ammo, armour, medkits and bandages all
exist in the city already, so they use ox's image and look the same in both
places -- that is the right default and you should leave it alone.

Only items with no city version need a picture here:

    rz_coin.png        <- shipped
    naija_slurpy.png   <- shipped
    n46_gummies.png

Drop a PNG in with the item's id as the filename, then add that id to the
OWN_IMAGES list at the top of html/app.js. Both steps are needed -- the list
is what tells the interface to look here instead of at ox.

Until you do, they fall through to ox. If ox has no image either, the slot
shows the item's name instead of a broken picture, so nothing looks broken
while you are still making the art.

128x128 is plenty -- they render at roughly 60px in the grid and 44px in the
shop. The coin arrived at 512x512 and 208 KB; resized it is under 30 KB for no
visible difference, and that file is loaded by every player who opens their
inventory.

--

If you DO want one of these to exist in the city as well -- something people
can carry around in ox_inventory outside the arena -- then it needs a normal
ox item definition and an image in ox_inventory/web/images. That is a separate
thing from this script working.
