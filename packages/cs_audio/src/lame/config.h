/* Configuración fija de LAME para CS Mix (Android NDK, MSVC y GCC/Clang).
 * Solo se compila el codificador: sin decodificador mpglib, sin NASM ni SSE. */
#ifndef CS_LAME_CONFIG_H
#define CS_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1

/* Todas las plataformas de destino usan float IEEE-754 de 32 bits. */
#define TAKEHIRO_IEEE754_HACK 1
#define USE_FAST_LOG 1
typedef float ieee754_float32_t;

#define PACKAGE "lame"
#define VERSION "3.100"

#endif
