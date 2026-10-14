#!/usr/bin/env python3
"""Notificación de escritorio con botones; imprime la clave del botón pulsado.

Sustituye a `notify-send -A`, que en Ubuntu no muestra botones: su perfil de AppArmor
(/etc/apparmor.d/notify-send) le prohíbe llamar a GetCapabilities y recibir ActionInvoked.

Uso: preguntar.py [--app NOMBRE] [--timeout SEG] -A clave=Etiqueta [-A ...] TITULO CUERPO
Sale con 0 e imprime la clave si se pulsa un botón; con 1 si se cierra o vence el tiempo
(en ese caso retira la notificación para que no quede un botón muerto en la bandeja).
"""
import argparse
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS_NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
URGENCIA_CRITICA = 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default="preguntar")
    ap.add_argument("--timeout", type=int, default=900, help="segundos de espera")
    ap.add_argument("-A", dest="acciones", action="append", required=True, metavar="clave=Etiqueta")
    ap.add_argument("titulo")
    ap.add_argument("cuerpo")
    args = ap.parse_args()

    acciones = []
    for a in args.acciones:
        clave, _, etiqueta = a.partition("=")
        acciones += [clave, etiqueta or clave]

    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    loop = GLib.MainLoop()
    resultado = {"id": None, "clave": None}

    def on_signal(_conn, _sender, _path, _iface, señal, params, _data):
        if resultado["id"] is None or params[0] != resultado["id"]:
            return
        if señal == "ActionInvoked":
            resultado["clave"] = params[1]
        loop.quit()

    for señal in ("ActionInvoked", "NotificationClosed"):
        bus.signal_subscribe(BUS_NAME, BUS_NAME, señal, PATH, None, Gio.DBusSignalFlags.NONE, on_signal, None)

    hints = {"urgency": GLib.Variant("y", URGENCIA_CRITICA)}
    respuesta = bus.call_sync(
        BUS_NAME, PATH, BUS_NAME, "Notify",
        GLib.Variant("(susssasa{sv}i)", (args.app, 0, "", args.titulo, args.cuerpo, acciones, hints, 0)),
        GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None,
    )
    resultado["id"] = respuesta[0]

    GLib.timeout_add_seconds(args.timeout, loop.quit)
    loop.run()

    if resultado["clave"] is None:
        try:
            bus.call_sync(BUS_NAME, PATH, BUS_NAME, "CloseNotification",
                          GLib.Variant("(u)", (resultado["id"],)), None, Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error:
            pass  # ya estaba cerrada
        return 1
    print(resultado["clave"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
