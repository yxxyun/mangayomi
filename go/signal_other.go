//go:build !ios
// +build !ios

package server

import (
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

func signalHandler() {
	signal.Ignore(syscall.SIGPIPE)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("[INFO] Termination detected. Removing torrents")
		for _, t := range torrentCli.Torrents() {
			log.Printf("[INFO] Removing torrent: [%s]\n", t.Name())
			t.Drop()
			rmaErr := os.RemoveAll(filepath.Join(torrentcliCfg.DataDir, t.Name()))
			if rmaErr != nil {
				log.Printf("[ERROR] Failed to remove files of torrent: [%s]: %s\n", t.Name(), rmaErr)
			}
		}
		os.Exit(0)
	}()

}
