// Prueba de la web (Chromium sin cabeza, con Playwright) de los estados y la pulsación larga de 008.
// La función de borde se simula (sin Supabase): solo se comprueba la pantalla y lo que manda al servidor.
// Uso: node dispositivos/pruebas/ui_estados.js
const { chromium } = require('playwright');
const path = require('path');
const assert = require('assert');

const API = 'https://dbxlrnupiwemnarlxmcv.supabase.co/functions/v1/dispositivos';
const U = (n) => '00000000-0000-4000-8000-00000000000' + n;

function estadoInicial() {
  const base = { activo: true, tiene: null, desde: null, fuera: false, fuera_motivo: null, fuera_desde: null, estado: 'operativo', estado_nota: null, estado_desde: null, enlazado: true, pendiente_cs: false };
  return {
    ok: true, ahora: new Date().toISOString(), con_pin: true,
    dispositivos: [
      Object.assign({}, base, { id: U(1), nombre: '#1 Carretilla Linde', grupo: 'Máquina', serie: 'AAA' }),
      Object.assign({}, base, { id: U(2), nombre: '#2 Apilador Still', grupo: 'Máquina', serie: 'BBB', estado: 'fallo', estado_nota: 'frena un poco', estado_desde: new Date().toISOString() }),
      Object.assign({}, base, { id: U(3), nombre: '#3 Transpaleta Linde', grupo: 'Máquina', serie: 'CCC', estado: 'averiado', estado_nota: 'no frena', fuera: true, fuera_motivo: 'no frena', fuera_desde: new Date().toISOString() }),
      Object.assign({}, base, { id: U(4), nombre: '#4 Recepción', grupo: 'Móvil / lector', serie: 'ZY1' })
    ],
    personas: [{ id: 'p1', nombre: 'Ana Jefa', grupo: 'Jefe', activo: true }, { id: 'p2', nombre: 'Beto Operario', grupo: 'Operario', activo: true }],
    avisos: []
  };
}

(async () => {
  const navegador = await chromium.launch();
  const ctx = await navegador.newContext({ viewport: { width: 420, height: 900 }, hasTouch: false });
  const page = await ctx.newPage();
  const errores = [];
  page.on('pageerror', (e) => errores.push(e.message));
  let est = estadoInicial();
  const llamadas = [];
  await page.route(API, async (route) => {
    const cuerpo = JSON.parse(route.request().postData());
    llamadas.push(cuerpo);
    let res;
    if (cuerpo.accion === 'estado') res = est;
    else if (cuerpo.accion === 'comprobar_pin') res = cuerpo.args.pin === '1234' ? { ok: true } : { ok: false, codigo: 'pin', error: 'PIN no válido.' };
    else if (cuerpo.accion === 'cambiar_estado') {
      const a = cuerpo.args;
      const d = est.dispositivos.find((x) => x.id === a.dispositivo_id);
      d.estado = a.estado; d.estado_nota = a.nota || null; d.fuera = a.estado === 'averiado' || a.estado === 'reparacion';
      d.fuera_motivo = d.fuera ? a.nota : null; d.pendiente_cs = true;
      res = est;
    } else res = { ok: true };
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(res) });
  });
  await page.addInitScript(() => { try { localStorage.setItem('rd_clave', 'clave-de-prueba'); } catch (e) {} });
  await page.goto('file://' + path.resolve(__dirname, '../index.html'));
  await page.waitForSelector('.cuadro');

  const cuadro = (n) => page.locator('.cuadro', { hasText: '#' + n });
  const textoCuadro = async (n) => (await cuadro(n).innerText()).replace(/\s+/g, ' ');
  const largo = async (loc) => {
    const b = await loc.boundingBox();
    await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await page.mouse.down();
    await page.waitForTimeout(800);
    await page.mouse.up();
  };

  // 1) Cómo se ven los estados en los cuadros
  assert(/FALLO/.test(await textoCuadro(2)), 'el cuadro con fallo lleva la insignia FALLO');
  assert(/AVERIADO/.test(await textoCuadro(3)), 'el cuadro averiado dice AVERIADO');
  assert(!/FALLO|AVERIADO/.test(await textoCuadro(1)), 'el operativo no lleva insignia');
  assert(/LIBRE/.test(await textoCuadro(2)), 'con fallo se sigue viendo libre (se puede coger)');

  // 2) Un toque normal sigue cogiendo (no abre el menú de estados)
  await cuadro(1).click();
  await page.waitForSelector('.kmodal');
  assert(/Coger/.test(await page.locator('.kmodal h3').innerText()), 'un toque corto abre «Coger»');
  await page.keyboard.press('Escape');

  // 3) Con fallo: al coger sale el aviso con la nota
  await cuadro(2).click();
  await page.waitForSelector('.kmodal');
  assert(/frena un poco/.test(await page.locator('.kmodal').innerText()), 'al coger algo con fallo sale la nota del fallo');
  await page.keyboard.press('Escape');

  // 4) Averiado: mensaje y no se puede coger
  await cuadro(3).click();
  await page.waitForSelector('.kmodal');
  const t3 = await page.locator('.kmodal').innerText();
  assert(/Averiado/.test(t3) && /No se puede coger/.test(t3), 'la averiada avisa de que no se puede coger: ' + t3);
  assert(!(await page.locator('.kmodal button', { hasText: /^Coger/ }).count()), 'la averiada no ofrece coger');
  await page.keyboard.press('Escape');

  // 5) Pulsación larga sin PIN → pide el PIN → menú de estados
  await largo(cuadro(1));
  await page.waitForSelector('#pinCampo');
  assert(!(await page.locator('.kmodal h3', { hasText: /Coger/ }).count()), 'la pulsación larga no deja abierto «Coger»');
  await page.fill('#pinCampo', '1234');
  await page.waitForSelector('.op-estado');
  const nombres = await page.locator('.op-estado b').allInnerTexts();
  assert.deepStrictEqual(nombres.map((x) => x.replace(' · ahora', '')), ['Operativo', 'Con fallo', 'Averiado', 'En reparación'], 'una máquina: operativo, con fallo, averiado, en reparación');
  assert(await page.locator('.op-estado.operativo').isDisabled(), 'ya operativo: ese botón no hace nada');

  // 6) Elegir «Averiado» → quién + qué le pasa → llega bien al servidor
  await page.locator('.op-estado.averiado').click();
  await page.waitForSelector('.kmodal textarea, .kmodal input[type=text]');
  await page.locator('.btn-operario', { hasText: 'Ana Jefa' }).click();
  await page.locator('.kmodal textarea, .kmodal input[type=text]').first().fill('se oye un golpe al frenar');
  await page.locator('.fila-botones .btn', { hasText: /Averiado/ }).click();
  await page.waitForFunction(() => /AVERIADO/.test(document.body.innerText) && !document.querySelector('.kmodal'));
  const env = llamadas.filter((x) => x.accion === 'cambiar_estado').pop();
  assert(env && env.args.estado === 'averiado' && env.args.persona === 'Ana Jefa' && env.args.nota === 'se oye un golpe al frenar' && env.args.dispositivo_id === U(1) && env.args.pin === '1234', 'payload de cambiar_estado: ' + JSON.stringify(env));
  assert(/AVERIADO/.test(await textoCuadro(1)), 'el cuadro pasa a AVERIADO');

  // 7) Ya con el PIN dentro: pulsación larga abre el menú directamente; un móvil admite «Baja» pero no «Con fallo»
  await page.locator('.seccion', { hasText: 'Dispositivos' }).click();
  await largo(cuadro(4));
  await page.waitForSelector('.op-estado');
  const nm = (await page.locator('.op-estado b').allInnerTexts()).map((x) => x.replace(' · ahora', ''));
  assert.deepStrictEqual(nm, ['Operativo', 'Averiado', 'En reparación', 'Baja'], 'un móvil: operativo, averiado, en reparación, baja');
  await page.keyboard.press('Escape');
  await page.locator('.seccion', { hasText: 'Máquinas' }).click();

  // 8) Soltar el dedo/ratón después de la pulsación larga no cierra el menú ni coge el dispositivo
  await largo(cuadro(2));
  await page.waitForSelector('.op-estado');
  await page.waitForTimeout(700);
  assert(await page.locator('.op-estado').count() > 0, 'el menú sigue abierto tras soltar');
  assert(/Pendiente|Con fallo|frena/.test(await page.locator('.kmodal').innerText()), 'el menú enseña la nota del fallo');
  await page.keyboard.press('Escape');

  // 9) Pasar el ratón fuera antes de tiempo cancela la pulsación larga
  const b = await cuadro(2).boundingBox();
  await page.mouse.move(b.x + 20, b.y + 20);
  await page.mouse.down();
  await page.mouse.move(b.x + 120, b.y + 60, { steps: 5 });
  await page.waitForTimeout(800);
  await page.mouse.up();
  assert(!(await page.locator('.op-estado').count()), 'mover el dedo cancela la pulsación larga');

  assert.deepStrictEqual(errores, [], 'sin errores de JavaScript: ' + errores.join(' | '));
  await navegador.close();
  console.log('UI de estados: TODO OK');
})().catch((e) => { console.error('FALLO:', e.message); process.exit(1); });
