package tech.kalkikgp.linkit

fun ByteArray.toHex(): String = joinToString(separator = "") { "%02x".format(it) }
