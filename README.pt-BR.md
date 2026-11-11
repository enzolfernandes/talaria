# Talaria

**A hermes auto-server**

<img src="assets/sandal.svg" alt="Ícone da sandália alada do Talaria" width="160" height="160">

[Read in English](README.md)

## Objetivo

Facilitar o uso de múltiplos conectores com um mesmo gateway do Hermes no dia a dia.

O Talaria mostra o estado do servidor Hermes na bandeja do Windows, perto do relógio. Ele reaproveita um servidor autenticado ou configura o `hermes serve` para iniciar silenciosamente ao entrar na conta. Instale o Talaria no computador que hospeda o Hermes.

## Instalação

1. Use o Windows 10 ou 11 x64 e entre na conta que executa o Hermes.
2. Baixe `Instalar-Talaria.exe`. Você pode conferir o arquivo pelo checksum SHA-256 publicado com a versão. [Versões](https://github.com/enzolfernandes/talaria/releases)
3. Abra o instalador. Ele verifica a instalação nativa do Hermes, o endereço local do Tailscale e o servidor. Use a ação sugerida para resolver dependências ou conflitos de porta. [Hermes para Windows](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native) · [Tailscale para Windows](https://tailscale.com/docs/install/windows)
4. Selecione **Instalar indicador** quando o instalador confirmar a saúde do servidor, a presença de um provedor de login e a recusa de acesso anônimo. Se o Talaria criar credenciais, ele também fará login e encerrará a sessão de teste.

Clique na sandália alada para ver o endereço, o estado e a última verificação. Verde indica uma resposta válida. Amarelo indica espera ou nova tentativa. Vermelho indica três falhas consecutivas. Clique com o botão direito para verificar agora, copiar o endereço, abrir os logs ou o instalador, ou sair do indicador.

Abra **Manutenção** no instalador para reparar ou remover o indicador. Remover o indicador mantém o servidor em execução. **Reverter servidor** está disponível separadamente quando o Talaria criou o servidor.

## Dados locais

O Talaria reaproveita a autenticação existente no Hermes. As credenciais que ele cria ficam fora do repositório, em `%LOCALAPPDATA%\HermesServidor\server\credentials.local.json`, criptografadas para a conta atual do Windows com DPAPI. A configuração fica em um arquivo separado. Os backups dos arquivos e das definições de tarefas que o Talaria altera ficam em `%LOCALAPPDATA%\HermesServidor\backups`.

## Compilação e testes

Execute os comandos na pasta do repositório com Windows PowerShell 5.1 no Windows x64. A compilação usa o compilador do .NET Framework incluído no Windows.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts/Build.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts/Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Audit.ps1
```

O instalador e o checksum são gerados em `dist`. Execute `scripts/Test.ps1 -Integration` em uma sessão interativa do Windows para testar a instalação com tarefas temporárias, servidor e rede simulados.

## Licença e créditos

O Talaria é um projeto independente com [licença MIT](LICENSE). A sandália alada é original e a interface segue referências visuais do Hermes Desktop e do Hermes Setup, da Nous Research. [Licença do Hermes Agent](https://github.com/NousResearch/hermes-agent/blob/main/LICENSE) · [Código do Hermes Setup](https://github.com/NousResearch/hermes-agent/tree/main/apps/bootstrap-installer)
