# Talaria

**Um servidor automático para o Hermes**

<p align="center">
  <img src="assets/sandal.svg" alt="Ícone da sandália alada do Talaria" width="160" height="160">
</p>

O Talaria é um utilitário independente e não oficial para Windows, voltado ao **Hermes AI Agent da Nous Research**.

[Página oficial do Hermes](https://hermes-agent.nousresearch.com/) · [Baixar o Talaria](https://github.com/enzolfernandes/talaria/releases/latest) · [Read in English](README.md)

## Objetivo

Facilitar o uso de múltiplos conectores com um mesmo gateway do Hermes no dia a dia.

O Talaria roda no computador que hospeda o Hermes e mostra o estado do servidor na bandeja do Windows, perto do relógio. Ele pode reaproveitar um servidor autenticado ou configurar o `hermes serve` para iniciar silenciosamente ao entrar na conta.

## Instalação

A validação da v0.2.0 abrangeu o Windows 10 x64 e incluiu o acionamento manual das tarefas do servidor e do indicador pelo Agendador de Tarefas. A inicialização após um novo logon e o fluxo completo de instalação no Windows 11 seguem sem validação.

1. Use o Windows 10 ou 11 x64 e entre na conta que executa o Hermes.
2. Baixe `Talaria-Setup.exe`. Você pode conferir o arquivo pelo checksum SHA-256 publicado com a versão. [Versão mais recente](https://github.com/enzolfernandes/talaria/releases/latest)
3. Abra o instalador. Se faltar o Hermes Desktop ou o Tailscale, use a opção **Install** correspondente para abrir o instalador oficial. Se a CLI do Hermes já funcionar, você pode instalar o Desktop nessa mesma instalação ou escolher **Continue without Desktop**. [Hermes para Windows](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native) · [Tailscale para Windows](https://tailscale.com/docs/install/windows)
4. Abra o Tailscale e entre na conta quando solicitado. O Talaria verifica se a máquina recebeu um endereço do Tailscale. Use **Check again** após concluir uma instalação externa ou reiniciar o Windows.
5. Configure o servidor se o instalador solicitar. O Talaria reaproveita um servidor saudável e autenticado e as tarefas de início compatíveis. Selecione **Install indicator** após as verificações de saúde e autenticação. Se o Talaria criar credenciais, ele também fará login e encerrará a sessão de teste.

Se o instalador oficial do Hermes informar que não encontrou o WebView2, instale o Microsoft Evergreen WebView2 Runtime e selecione **Install Hermes Desktop** novamente. [Download do Microsoft WebView2](https://developer.microsoft.com/pt-br/microsoft-edge/webview2/#download-section)

Se o instalador oficial parar com `WinError 3` ao copiar um arquivo cujo caminho ultrapassa 260 caracteres, habilite os **caminhos longos do Win32** no Windows e reabra o instalador. [Documentação da Microsoft sobre caminhos longos](https://learn.microsoft.com/pt-br/windows/win32/fileio/maximum-file-path-limitation#enable-long-paths-in-windows-10-version-1607-and-later)

Clique na sandália alada para ver o endereço, o estado e a última verificação. Verde indica uma resposta válida. Amarelo indica espera ou nova tentativa. Vermelho indica três falhas consecutivas. Clique com o botão direito para verificar agora, copiar o endereço, abrir os logs ou o instalador, ou sair do indicador.

Abra **Maintenance** no instalador para reparar ou remover o indicador. Remover o indicador mantém o servidor em execução. **Revert server setup** está disponível separadamente quando o Talaria criou o servidor.

## Capturas de tela

O instalador após verificar uma conexão protegida. O endereço e a pasta são exemplos.

![Instalador do Talaria com as verificações de Hermes, Tailscale e conexão concluídas](assets/screenshots/installer.png)

A sandália alada na bandeja do Windows e o painel de status conectado a um servidor local de teste.

![Painel do Talaria mostrando um servidor de teste em execução acima do ícone da bandeja](assets/screenshots/tray.png)

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
