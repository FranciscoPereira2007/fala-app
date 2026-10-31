# Fala

**A tua voz, em todo o lado.** Dita, conversa com os teus agentes e controla o teu computador a partir do iPhone.

Este é o **projeto completo da Fala**, agora aberto sob a licença [MIT](LICENSE): frontend original, apps Mac e iOS, app Windows, teclado, widgets e backend do relay. O código Android também está incluído.

## Instalar

- **Mac e Windows:** [downloads nas Releases](https://github.com/FranciscoPereira2007/fala-app/releases/latest) — `Fala.dmg` e `FalaSetup.exe`.
- **iPhone/iPad:** [beta no TestFlight](https://testflight.apple.com/join/TzdQZ3GS), sujeita à disponibilidade da beta.

Os instaladores já publicados têm a sua própria versão/data; esta abertura do código não substitui automaticamente esses binários.

Abre a Fala no computador e lê o QR na app do iPhone para emparelhar. Mantém o código privado.

## O que está incluído

| Pasta | Componente |
|---|---|
| `Mac/` | App macOS com o frontend completo, ditado, sessões, voz e controlo remoto |
| `iOS/` | App iPhone/iPad completa |
| `Shared/` | Protocolo, cifra, áudio, modelos e componentes partilhados |
| `Keyboard/`, `Widgets/` | Teclado iOS, widgets e Live Activities |
| `pc-node/` | App Windows, serviço local, captura/controlo do ecrã e instalador |
| `relay/` | Cloudflare Worker, Durable Objects, contas e site |
| `android/` | Cliente Android existente |
| `research/link-tests/`, `research/jarvis-tests/` | Testes e ferramentas do protocolo |

As funções dependem da plataforma e das permissões concedidas. Claude Code/Codex precisam da instalação e da conta do próprio utilizador. Os modelos locais de voz são dependências opcionais; os pesos e os ambientes Python não estão incluídos no Git.

## Compilar Mac e iOS

Requer macOS, **Xcode 26 ou superior** (SDK com SpeechAnalyzer) e [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/FranciscoPereira2007/fala-app.git
cd fala-app
xcodegen generate
open Fala.xcodeproj
```

Seleciona `FalaMac` para Mac ou `Fala` para iPhone. Para instalar num dispositivo, seleciona **a tua própria equipa Apple** em Signing & Capabilities. As configurações pessoais de assinatura do autor foram retiradas. Um fork pode precisar de alterar os bundle identifiers e os grupos partilhados.

O projeto inclui Sign in with Apple e CarPlay: estas capacidades exigem configuração/perfis válidos da tua equipa; CarPlay depende de autorização da Apple. Para verificar só a compilação:

```sh
xcodebuild -project Fala.xcodeproj -scheme FalaMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Fala.xcodeproj -scheme Fala \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

A primeira preparação dos modelos de voz pode demorar. A Fala usa permissões de microfone, rede local e, conforme as funções usadas, Acessibilidade, Gravação do ecrã e Automação. Não atives controlo remoto para aparelhos em que não confies.

## Windows a partir do código

Requer Windows e Python 3.12 com Tkinter.

```powershell
cd pc-node
py -3.12 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe fala_app.py
```

Para gerar o instalador, segue `pc-node/build/build.ps1`; esse script obtém PyInstaller, FFmpeg e Inno Setup. O Whisper com GPU, Piper e Chatterbox são opcionais, instalados à parte. O modo normal não exige estes modelos no PC: pode receber o ditado do telefone.

## Relay e contas

```sh
cd relay
npm ci
npx wrangler dev --local --port 8798 --var FALA_TEST:1
```

Noutro terminal, com [Bun](https://bun.sh) instalado:

```sh
bun relay/test.mjs http://127.0.0.1:8798
node relay/test-accounts.mjs http://127.0.0.1:8798
```

`FALA_TEST` é exclusivamente para testes locais e **não deve ser configurado em produção**. Para alojar um relay próprio, usa a tua conta Cloudflare, as bindings de `wrangler.toml` e os bundle identifiers Apple correspondentes. Atualiza a URL nas preferências `fala.relay` (Apple), `pc-node/relay_link.py` e no cliente Android. A publicação deste código não cria nem faz deploy de uma infraestrutura tua.

## Validação e privacidade

Consulta [VALIDATION.md](docs/VALIDATION.md) para os testes realizados e os limites da validação. [SECURITY.md](SECURITY.md) descreve as fronteiras de confiança do relay, das contas e da rede local. [PROTOCOL.md](docs/PROTOCOL.md) e [REMOTE.md](docs/REMOTE.md) documentam o transporte.

Esta publicação contém uma cópia limpa do código da aplicação. Não contém o histórico privado de desenvolvimento, chaves, certificados, credenciais de contas, gravações, transcrições pessoais ou bases de dados do serviço.

## Contribuir e licença

Relata problemas com a plataforma, versão, passos para reproduzir e logs sem códigos de emparelhamento nem dados pessoais. Contribuições são recebidas sob MIT. Fontes, modelos e dependências mantêm as suas próprias licenças: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
