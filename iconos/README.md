# Iconos de Taisa

La «T» de Taisa (cuadrado rojo, recortado del logo que ya usa Centinela) en cuatro tamaños, para usarlos como icono
de las apps. Quedan publicados en GitHub Pages:

- `https://guenroo-lab.github.io/registro-incidencias/iconos/taisa-t-512.png`
- `https://guenroo-lab.github.io/registro-incidencias/iconos/taisa-t-192.png`
- `https://guenroo-lab.github.io/registro-incidencias/iconos/taisa-t-180.png` (iPhone)
- `https://guenroo-lab.github.io/registro-incidencias/iconos/taisa-t-64.png` (pestaña del navegador)

## En una app de Google Apps Script

El icono de la pestaña y del acceso directo se pone con `setFaviconUrl` sobre lo que devuelve `doGet`. Solo admite una
URL `https://` real que acabe en `.png`, no un `data:`. Un fallo ahí no debe tumbar la app, así que va en `try/catch`
(en `.gs`, sin flechas ni plantillas de texto):

```js
var salida = HtmlService.createHtmlOutputFromFile('Index');
try {
  salida.setFaviconUrl('https://guenroo-lab.github.io/registro-incidencias/iconos/taisa-t-192.png');
} catch (e) {}
return salida;
```

Apps Script no deja poner `apple-touch-icon`, que es el que usa el iPhone: allí el icono del acceso directo puede
seguir saliendo como una letra. En Android (Chrome) debería salir la T.

## La «K» de Kairos

Cuadrado rojo Taisa con la K en la letra de rotulador del nombre «Kairos» (Permanent Marker), en cuatro tamaños:

- `https://guenroo-lab.github.io/registro-incidencias/iconos/kairos-k-512.png`
- `https://guenroo-lab.github.io/registro-incidencias/iconos/kairos-k-192.png` (la que usa Kairos en la pestaña)
- `https://guenroo-lab.github.io/registro-incidencias/iconos/kairos-k-180.png` (iPhone)
- `https://guenroo-lab.github.io/registro-incidencias/iconos/kairos-k-64.png`
