# Home NAS

## 1. Instalace OS

* Stáhnout ISO
* Bootnout
* Nastavení root usera
* Nastavení NIC
* Vypnutí enterprise repozitářů a nastavení běžných uživatelských

## 2. Nastavení Github ENV Secrets/Vars

* Rozvrhnout si jaké budou mít formát názvů aby se v těch desítkách proměnnách dalo orientovat
* Rozmyslet si, co vše budou proměnný umožňovat a co naopak je zbytečný
* Všechny důkladně odokumentovat k čemu slouží, kde například danou hodnotu najdu, a co vše ovlivňuje

## 3. Naprogramovat CI/CD stack

### 3.0 První nasazení proces

* 3.0.1 Rozhodnout, jak přistoupit k prvnímu nasazení (bash only, bash + gh actions, gh actions only)
* 3.0.2 Zmapovat co vše tenhle script bude muset nastavit a co naopak bude duplicitní vůči CD
* 3.0.3 Napsat to

### 3.1 CI pipeline

* 3.1.1 Nastavit základní pravidla kdy se má CI spouštět
* 3.1.2 Udělat linting pro pomocný bash scripty
* 3.1.3 Udělat linting pro terraform configy
* 3.1.4 Vygenerovat terraform plan a ten někam uložit pro deployment
* 3.1.5 Udělat linting pro Ansible
* 3.1.6 Udělat linting pro Docker

### 3.2 CD pipeline

* 3.2.1 Nastavit základní zabezpečení a pravidla tak, aby se to dalo spustit jen z main branche atd.
* 3.2.2 Stáhnout Terraform plan z CI pipeline a kouknout se na změny oproti předchozí verzi
* 3.2.3 Kouknout se zda se něco změnilo v Ansible nebo Terraform vrstvě a případně updatnout Ansible
* 3.2.4 Pokud se něco změnilo ve vrstvách Docker, Ansible, nebo Terraform nahodit změny pro Docker

### 3.3 Terraform vrstva

* 3.3.1 Rozvrhnout si VMka a LCX managed/unmanaged containery
* 3.3.2 Naprogramovat strukturu LXC a VMek
* 3.3.3 Nadefinovat všechny variables a vytáhnout je z Githubu

### 3.4 Ansible vrstva

* 3.4.1 Zjistit co vše je v jednotlivých VMkách/LXC potřeba nakonfigurovat nebo nainstalovat
* 3.4.2 Nadefinovat všechny potřebné balíčky a konfigurace
* 3.4.3 Nastavení všech proměnných a provázání je s Githubem

### 3.5 Docker vrstva

* 3.5.1 Rozmyslet si co vše tam vlastně poběží a kde
* 3.5.2 Nadefinovat Docker composy
* 3.5.3 Rozvrhnout strukturu dat jednotlivých kontejnerů na disku
* 3.5.4 Nalinkovat volumes na správný storage (RAID pool nebo OS drive)

## 4 Rozběhnutí storage poolu

* 4.1 Nakonfigurování potřebných proměnných v Githubu
* 4.2 Vytvoření RAID5 poolu
* 4.3 Naformátování pole
* 4.4 Nastavení přístupu ostatních VM/LXC

## 5. Backup a monitoring

* Rozvržení záloh konfigurace
* Rozmyslení si zálohování dat z poolu
* Přidat toolky na monitoring
* Nastavení alertingu

## 5. Dokumentace, návody

### 5.1 Dokumentace kódu

* 5.1.1 Určit si standardy pro jednotlivé části kódu
* 5.1.2 Naimplementovat standardy do linerů
* 5.1.3 Standardy použít v celém kódu

### 5.2 Dokumentace projektu jako celku

* 5.2.1 Rozvrhnout si strukturu markdownů a sepsat rozcestník do root readme
* 5.2.2 Sepsat jednotlivé markdowny

### 5.3 Návody pro širokou veřejnost

* 5.3.1 Udělat návod na instalaci OS
* 5.3.2 Udělat návod na nastavení repozitáře a proměnných společně s základním nastavením systému
* 5.3.3 Udělat návod na prvotní nasazení
* 5.3.4 Udělat návod na dělání změn
* 5.3.5 V krátkosti popsat co se kde dá upravit a co je kde potřeba změnit třeba v případě přidávání dalšího VM s Dockerem a images
