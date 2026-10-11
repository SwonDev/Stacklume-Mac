# Privacidad en Stacklume para Mac

La biblioteca, los documentos importados, las conversaciones y la inferencia de los modelos locales se procesan en tu Mac. Las funciones que consultan internet sí se conectan a los sitios o proveedores correspondientes. Puedes elegir qué automatizaciones y búsquedas permites.

## Datos locales

| Dato | Almacenamiento |
|---|---|
| Enlaces, colecciones, etiquetas y ajustes de dominio | Store SwiftData en el soporte de aplicaciones del usuario. |
| Conversaciones del asistente | JSON local de Stacklume, separado del store de biblioteca. |
| Progreso, notas de resaltados y portadas propias | Stores laterales locales asociados al enlace. |
| Texto extraído e índice semántico | Corpus e índice local de la búsqueda. |
| Pesos y runtime de EmbeddingGemma 2 | Directorio local de Stacklume para su motor de búsqueda. |
| Copias automáticas | Directorio local de copias de Stacklume. |
| Credenciales de integraciones que configures | Almacenamiento seguro previsto por la integración, como el Llavero. |

El código abierto no publica estos archivos ni convierte tu biblioteca en una biblioteca compartida. Tampoco implica cifrado de todos los datos locales: protege tu cuenta de macOS, el disco y las copias que exportes.

## Cuándo se conecta a internet

| Función | Datos que necesita enviar |
|---|---|
| Metadatos y portadas de un enlace | Solicitudes al sitio del enlace y a los recursos que proporcionan sus metadatos. |
| Abrir o previsualizar una web | La URL y las solicitudes necesarias para cargar esa página. El sitio puede aplicar sus propias cookies y políticas. |
| Iconos de terceros, si activas esa opción | El dominio del enlace a Google o DuckDuckGo. Desactivado por defecto. |
| Búsqueda web del asistente | Una consulta de búsqueda a DuckDuckGo y solicitudes a las páginas que lea. |
| Descubrir, Hugging Face y Civitai | Consultas, filtros y solicitudes de contenido al proveedor correspondiente. |
| Descargar modelos locales | Identificadores y solicitudes de archivos al alojamiento del modelo. Los pesos descargados se ejecutan localmente. |
| Actualizaciones de la aplicación | Solicitudes al canal de distribución de GitHub. |
| Integraciones conectadas por el usuario | Las solicitudes necesarias para la función y los permisos de esa cuenta. |

Los servicios externos pueden observar la dirección IP y los datos de sus solicitudes. Guardar una URL privada o con parámetros sensibles merece la misma precaución que abrirla en un navegador.

La búsqueda web del asistente está activada por defecto. La cabecera indica su estado y el ajuste de IA permite desactivarla. El cliente envía la consulta, no una exportación de la biblioteca; una consulta puede contener información sensible si la escribes en tu petición. La inferencia del modelo y el tratamiento de las fuentes recuperadas siguen siendo locales.

## Controles del usuario

- La sugerencia desde el portapapeles está desactivada por defecto. Se activa desde los ajustes de privacidad.
- Spotlight puede mostrar metadatos de tus enlaces. Incluir descripciones, notas y texto de documentos requiere un permiso adicional; puedes retirar el índice desde los ajustes.
- Las capacidades de Atajos y automatización tienen permisos separados para capturar, consultar y organizar. Puedes revocarlos.
- Puedes desactivar la búsqueda web y el autocompletado con IA. Los modelos cargados ofrecen controles para liberar memoria.
- Las exportaciones y copias se guardan en el destino local que corresponda. Si eliges un destino sincronizado por otro programa, ese programa controla su sincronización.

Las opciones de tamaño de texto, movimiento, transparencia y tecnologías de asistencia siguen los ajustes de la app y de macOS. Su uso no requiere publicar datos ni crear una cuenta.

## Copias, borrado y desinstalación

Las copias pueden incluir enlaces, notas, resaltados, adjuntos y portadas. Guárdalas como documentos privados. El historial del asistente se almacena por separado: no des por hecho que una exportación de biblioteca incluye todos los datos de la aplicación.

Consulta el alcance de cada acción de borrado antes de confirmarla. Las copias conservadas y las exportaciones que hayas creado requieren su propia gestión. Mover la aplicación a la Papelera no elimina automáticamente el soporte de aplicaciones, los modelos, las copias ni las credenciales guardadas en el Llavero.

## Informes y contribuciones

Antes de compartir un log, una captura o una reproducción, retira URL privadas, contenido de conversaciones, nombres de archivos, rutas de usuario y credenciales. Usa datos sintéticos en las issues públicas. La [guía de contribución](../CONTRIBUTING.md) explica cómo comprobar cambios sin usar tu biblioteca habitual.

La [política de la web](https://stacklume.app/privacy) describe sus propios servicios. La descarga gratuita de la aplicación para Mac no requiere registrarse ni facilitar datos de pago.
