# EcoFab Lab: registro de residuos por QR

| Página | Para quién | Acceso |
|---|---|---|
| `/registro` | Público, desde el celular (QR) | Abierto, sin cuenta |
| `/panel` | Equipo del laboratorio, en PC o tablet | Con correo y contraseña |
| `/qr` | Montar la demo | Hoja imprimible |
| `/` | Redirige: celular → registro, PC → panel | |

## 1. Supabase

1. Abre `supabase/esquema.sql` y cambia `CAMBIA-ESTE-TOKEN` (al final) por una clave larga inventada.
2. En Supabase, abre el SQL Editor, pega el archivo completo y ejecútalo.
3. En la configuración de Authentication, desactiva que se puedan registrar usuarios nuevos por su cuenta.
4. En Authentication > Users, crea los usuarios del equipo (correo y contraseña).
5. Autoriza cada usuario para el panel, ejecutando en el SQL Editor:
   ```sql
   insert into public.staff (user_id, nombre)
   select id, 'Nombre' from auth.users where email = 'correo@ejemplo.cl';
   ```
6. Copia la URL del proyecto y la clave anon o publishable (Project Settings > API) en `config.js`.

## 2. Vercel

1. Sube esta carpeta a un repositorio de GitHub (sin la carpeta `esp32` si prefieres).
2. En Vercel, crea un proyecto nuevo desde ese repositorio. No necesita framework ni comando de build.
3. Abre `https://TU-PROYECTO.vercel.app/qr` desde la dirección definitiva e imprime la hoja.

## 3. ESP32

Abre `esp32/contenedor_ecofab_wifi/contenedor_ecofab_wifi.ino` y completa WiFi (2,4 GHz), URL y clave de Supabase,
y el mismo token del paso 1.1. El panel mostrará "Sensor en línea" cuando lleguen lecturas.

## Seguridad

- La clave anon/publishable es pública por diseño; nunca uses la `service_role` o `secret` en estos archivos.
- El público solo puede insertar registros. No puede leerlos ni cambiar niveles.
- El nivel de cada contenedor lo calcula la base de datos, no el celular.
- Límite global: 30 registros por minuto.
- El sensor solo puede enviar lecturas si conoce el token del dispositivo.
