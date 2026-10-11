# Contribuir a Stacklume para Mac

Las contribuciones deben conservar la biblioteca del usuario, la identidad visual de Stacklume y la elección de sus modelos locales. Puedes proponer una mejora, corregir un fallo o ampliar las pruebas.

## Preparar el proyecto

Sigue los [comandos del README](README.md#compilar-desde-el-código). El bootstrap genera `Stacklume.xcodeproj` a partir de `project.yml` y copia el lockfile Swift al proyecto generado. Los paquetes propios están incluidos en `Packages/`; el checkout se puede compilar de forma autónoma.

Antes de implementar, busca si la función ya existe. La mayor parte del comportamiento específico de Mac vive en `App/`; los paquetes propios comparten el dominio con otras plataformas de Stacklume. Un cambio en esos modelos o en el formato de las copias requiere revisar su compatibilidad antes de integrarlo.

## Trabajar sin arriesgar tu biblioteca

Una compilación de desarrollo puede acceder a los datos locales de Stacklume. Usa una cuenta de macOS dedicada a pruebas o un entorno aislado con datos sintéticos. Conserva una exportación antes de probar importaciones, migraciones o acciones destructivas.

Para material visual, el código incluye un modo de demostración con la interfaz real, activado por `--stacklume-marketing-demo <escena>`. Su uso debe comprobarse con la build concreta: una captura pública nunca debe mostrar una biblioteca personal, rutas locales, conversaciones, tokens o ventanas ajenas.

No añadas modelos descargados, stores, copias de seguridad, conversaciones, credenciales, perfiles de firma, informes privados ni logs personales al repositorio. Usa datos sintéticos mínimos para reproducir un fallo.

## Implementar una mejora

- Reutiliza `LinkIngest` para dar de alta enlaces y `EntityResolver` para resolver colecciones y etiquetas.
- Conserva las ediciones manuales de títulos y descripciones; el enriquecimiento debe respetar `UserEditLedger`.
- Usa almacenamiento lateral por identificador cuando una función de Mac necesite datos adicionales sin cambiar el modelo compartido.
- Mantén la concurrencia estricta y el aislamiento de SwiftData. La cancelación debe detener el trabajo que la pantalla ya no necesita.
- Conserva los identificadores y precisiones de los modelos seleccionados. Un cambio de modelo requiere una decisión explícita.
- Escribe texto visible y documentación en español correcto, con codificación UTF-8.

## Cambios de interfaz

Lee [DESIGN.md](DESIGN.md) antes de modificar una vista. Usa los tokens de `StacklumeDesignSystem`, el lenguaje navy y dorado existente y los componentes nativos. El cristal pertenece a controles y navegación; el contenido conserva superficies legibles.

Comprueba el tamaño mínimo de la ventana, los temas afectados, el desplazamiento, el foco y las opciones de texto y movimiento. Las adaptaciones de accesibilidad deben respetar los ajustes del usuario y conservar el funcionamiento habitual de la app.

## Verificar y enviar una propuesta

1. Regenera el proyecto si cambias su lista de archivos Swift.
2. Compila la app con `-skipMacroValidation`.
3. Ejecuta las pruebas relacionadas con el cambio. Para lógica autocontenida, añade el archivo a las fuentes de `StacklumeTests` en `project.yml`.
4. Comprueba el comportamiento en una build identificable de la app. Un test de lógica no demuestra por sí solo un resultado visual, una descarga o una inferencia real.
5. Abre una pull request que explique el problema, el comportamiento resultante y la verificación realizada. Adjunta capturas sólo de datos sintéticos cuando el cambio sea visual.

Incluye los pasos para reproducir un fallo, versión de macOS y versión/build de Stacklume. Si un detalle contiene información sensible, describe su tipo y la causa sin publicarlo en una issue abierta.

Al aportar código aceptas distribuir tu contribución bajo la [licencia MIT del proyecto](LICENSE). Conserva los avisos de autoría y las licencias de terceros que incorpores.
